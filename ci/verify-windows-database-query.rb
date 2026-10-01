# frozen_string_literal: true

require "yaml"
require "pg"

configuration = YAML.safe_load_file(File.expand_path("~/.msf4/database.yml"), aliases: true).fetch("production")
raise "Expected local TCP database" unless configuration.fetch("host") == "127.0.0.1"
connection = nil
begin
  connection = PG.connect(
    host: configuration.fetch("host"),
    port: configuration.fetch("port", 5432),
    dbname: configuration.fetch("database"),
    user: configuration.fetch("username"),
    password: configuration.fetch("password"),
    connect_timeout: 10,
  )
  result = connection.exec("SELECT 1 AS value, current_database() AS database")
  unless result.ntuples == 1 && result[0]["value"] == "1" &&
      result[0]["database"] == configuration.fetch("database")
    raise "Packaged PostgreSQL query returned an unexpected result"
  end
  puts "WINDOWS_PACKAGED_POSTGRESQL_QUERY_PASSED value=1 server_version=#{connection.server_version}"
ensure
  connection&.finish
end
