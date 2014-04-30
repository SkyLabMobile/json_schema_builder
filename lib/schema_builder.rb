require 'json'
require 'schema_builder/version'
require 'schema_builder/writer'
require 'schema_builder/railtie' if defined? ::Rails::Railtie

module SchemaBuilder
  Mime::Type.register "application/schema+json", :schema

  ActionController::Renderers.add :schema do |schema, options|
    self.content_type ||= Mime::SCHEMA
    require 'schema_builder'
    SchemaBuilder::Writer.new.to_schema(schema.class)
  end
end
