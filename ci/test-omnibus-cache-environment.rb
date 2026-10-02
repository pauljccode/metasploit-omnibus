# frozen_string_literal: true

require "bundler/setup"
require "omnibus"
require "open3"
require "rbconfig"

preload = File.expand_path("nokogiri-archive-cache.rb", __dir__).tr("\\", "/")
raise "Unsupported whitespace in preload path" if preload.match?(/\s/)
old_options = ENV["RUBYOPT"]
ENV["RUBYOPT"] = "-r#{preload}"
probe = 'require "rubygems/installer"; puts Gem::Installer.ancestors.any? { |ancestor| ancestor.name == "NokogiriArchiveCache" }'
builder = Omnibus::Builder.new(nil)
begin
  builder.send(:with_clean_env) do
    raise "Omnibus did not clean inherited Ruby options" if ENV.key?("RUBYOPT")
    output, error, status = Open3.capture3(RbConfig.ruby, "-e", probe)
    raise "Inherited preload unexpectedly survived: #{error}" unless status.success? && output.strip == "false"

    command_env = { "RUBYOPT" => "-r#{preload}" }
    output, error, status = Open3.capture3(command_env, RbConfig.ruby, "-e", probe)
    raise "Explicit command preload was not loaded: #{error}" unless status.success? && output.strip == "true"
  end
  raise "Omnibus did not restore the caller environment" unless ENV["RUBYOPT"] == "-r#{preload}"
  puts "OMNIBUS_CACHE_ENVIRONMENT_BOUNDARY_PASSED"
ensure
  ENV["RUBYOPT"] = old_options
end
