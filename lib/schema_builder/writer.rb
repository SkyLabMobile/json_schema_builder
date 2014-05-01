require 'active_record'
module SchemaBuilder

  # Create json schema files for each model in
  # Rails.root/json-schema/modelName.json
  # @example
  #   builder = SchemaBuilder::Writer.new
  #   builder.write
  class Writer
    # [Array<Journey::Routes>] from Rails.application.routes.routes.routes
    attr_accessor :routes

    # Create schema files
    def write
      out = {:new => [], :old => [] }
      create_out_path
      models_as_hash.each do |model|
        file = File.join( out_path, "#{model['title'].underscore}.json")
        FileUtils.mkdir_p(File.dirname(file)) unless File.exists?(File.dirname(file))
        if File.exist? file
          out[:old] << file
        else
          File.open( file, 'w+' ) {|f| f.write(JSON.pretty_generate(model)) }
          out[:new] << file
        end
      end
      unless out[:old].empty?
        puts "== Existing Files ==\n"
        puts "Please rename them before they can be re-generated\n"
        puts out[:old].join("\n")
      end
      puts "== Created Files ==\n" unless out[:new].empty?
      puts out[:new].join("\n")
    end

    def to_schema model
      JSON.pretty_generate(to_schema_hash model)
    end
    def to_schema_hash model
      obj = { '$schema' => 'http://json-schema.org/draft-04/schema#' }
      prefix = model.name.tableize[/.*\//]
      model.reflections.each do |name,assoc|
        next if name == :versions
        obj['$ref'] = "/#{prefix}#{assoc.plural_name}/new.schema#" if assoc.macro == :belongs_to
      end if model.respond_to? :reflections
      obj.merge schema_template
      obj[:title] = model.name
      obj[:description] = model.name.titleize.sub(/\//,' ')
      props = {}
      model.columns_hash.each do |name, col|

        unless name =~ /(.*)_id$/ && assoc = model.reflections[$1.to_sym]
          prop = {}
          prop[:description] = name.titleize
          prop[:identity] = true if col.primary
          set_readonly(name,prop)
          set_type(col.type, prop)
          set_format(col.type, prop)
          prop[:default] = col.default if col.default
          prop[:maxlength] = col.limit if col.type == :string && col.limit
          props[name] = prop
        else
          next if assoc.macro == :belongs_to
          ref = { '$ref' => "/#{prefix}#{assoc.plural_name}/new.schema#" }
          if assoc.macro == :has_many
            (props[:many] ||= []) << [name]
            ref = {
                type: "array",
                format: "table",
                title: name.camelize,
                uniqueItems: true,
                items: ref
            }
          end
          props[$1.to_sym] = ref
        end
      end if model.respond_to? :columns_hash
      obj[:properties] = props
      #add links
      if links = links_as_hash[model.name.tableize]
        obj[:links] = links
      end
      obj
    end

    def models_as_hash
      out = []
      models.each do |model|
        out << to_schema_hash(model)
      end # models
      out
    end

    # Collect links from rails routes
    # TODO detect nesting /pdts/:pdt_id/pages/:id(.:format)
    #
    # @return [Hash{String=>Array<Hash{ String=>String }> } ]
    #   { 'articles' => [
    #       { 'rel' => 'create'
    #         'method' => POST
    #         'href' => 'articles/'
    #       },
    #       {more articles actions}
    #     ],
    #    'users' => []
    #   }
    def links_as_hash
      @links ||= begin
        skip_contrl = ['passwords', 'sessions', 'users', 'admin']
        skip_actions = ['edit', 'new']
        out = {}
        routes ||= Rails.application.routes.routes.routes
        routes.collect do |route|  #Journey::Route object
          reqs = route.requirements
          next if reqs.empty? ||
              skip_contrl.detect{|c| reqs[:controller][c] } ||
              skip_actions.detect{|a| reqs[:action][a] if reqs[:action].is_a? Array }

          # setup links ary
          out[ reqs[:controller] ] = [] unless out[reqs[:controller]]
          # add actions as hash
          unless out[ reqs[:controller] ].detect{ |i| i[:rel] == reqs[:action] }
            link = {
                rel: reqs[:action],
                method: route.verb.source.gsub(/[$^]/, ''),
                href: route.path.spec.to_s.gsub(/\(\.:format\)/, '').gsub(/:id/, '{id}')
            }
            out[reqs[:controller]] << link
          end
        end
        out
      end
    end

    #@return [Hash{String=>Mixed}] base json schema object hash
    def schema_template
      {
          type: 'object',
          title: '',
          description: 'object',
          properties: {},
          links: [],
      }
    end

    # @return [Array<Class>] classes(models) descending from ActiveRecord::Base
    def models
      Rails.application.eager_load!
      ActiveRecord::Base.descendants
    end

    def create_out_path
      FileUtils.mkdir_p(out_path) unless File.exists?(out_path)
    end

    def model_path
      @model_path ||= File.join( base_path, 'app/models', '**/*.rb')
    end

    # Set the model path
    # @param [String] path or file or pattern like models/**/*.rb
    def model_path=(path)
      @model_path = path
    end

    # Path to write json files
    def out_path
      @out_path ||= File.join( base_path, 'json-schema')
    end

    # @param [String] path to json schema files
    def out_path=(path)
      @out_path = path
    end

    # Base path to application/framework e.g. Rails.root.
    # Default to current working dir
    def base_path
      @base_path ||= Dir.pwd
    end
    def base_path=(path)
      @base_path = path
    end

    private

    # Set the type of the field property
    # JSON Schema types
    # - string
    # - number  Value MUST be a number, floating point numbers are
    #   allowed.
    # - integer  Value MUST be an integer, no floating point numbers are
    #   allowed.  This is a subset of the number type.
    # - boolean
    # @param [Symbol] col_type derived from ActiveRecord model
    # @param [Hash{String=>String}] hsh with field properties
    def set_type(col_type, hsh)
      hsh[:type] = if [:date, :datetime, :text].include?(col_type)
                     'string'
                   elsif col_type == :decimal
                     'number'
                   else
                     "#{col_type}"
                   end
    end

    # Set the format for a field property
    # @param [Symbol] col_type derived from ActiveRecord model
    # @param [Hash{String=>String}] hsh with field properties
    def set_format(col_type, hsh)
      if col_type == :datetime
        hsh[:format] = 'date-time'
      elsif col_type == :date
        hsh[:format]= 'date'
      end
    end

    # Set a field to read-only
    # @param [String] col_name derived from ActiveRecord model
    # @param [Hash{String=>String}] hsh with field properties
    def set_readonly(col_name, hsh)
      hsh[:readonly] = true if ['created_at', 'updated_at', 'id'].include?(col_name)
    end
  end
end
