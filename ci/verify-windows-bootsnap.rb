# frozen_string_literal: true

require "tmpdir"
require "rubygems"
require "rbconfig"

# Ignore the builder's gem environment when exercising the installed package.
root = File.expand_path(ARGV.fetch(0))
Gem.use_paths(File.join(root, "embedded/lib/ruby/gems", RbConfig::CONFIG.fetch("ruby_version")))
require "bootsnap"
require "bootsnap/compile_cache"

version = Gem.loaded_specs.fetch("bootsnap").version
raise "Bootsnap 1.26.1 or later is required" if version < Gem::Version.new("1.26.1")

previous_external = Encoding.default_external
previous_internal = Encoding.default_internal
begin
  Dir.mktmpdir("bootsnap-package") do |directory|
    Bootsnap::CompileCache.setup(cache_dir: File.join(directory, "cache"), iseq: true, yaml: false)
    fixtures = {
      "utf8" => ["# encoding: UTF-8\n# frozen_string_literal: true\n'caf\u00e9'\n", Encoding::UTF_8],
      "latin1" => ["# encoding: ISO-8859-1\n# frozen_string_literal: true\n'caf\xE9'\n".b, Encoding::ISO_8859_1]
    }
    fixtures.each do |name, (source, encoding)|
      [nil, Encoding::UTF_8, Encoding::ASCII_8BIT, Encoding::ISO_8859_1].each_with_index do |internal, index|
        path = File.join(directory, "#{name}-#{index}.rb")
        File.binwrite(path, source)
        Encoding.default_external = Encoding::ASCII_8BIT
        Encoding.default_internal = internal
        2.times do
          result = Bootsnap::CompileCache::ISeq.fetch(path).eval
          raise "Source encoding changed" unless result.encoding == encoding
          raise "Source bytes changed" unless result.b == source.b.lines.last.strip[1...-1]
          raise "Frozen string semantics changed" unless result.frozen?
        end
      end
    end
  end
ensure
  Encoding.default_external = previous_external
  Encoding.default_internal = previous_internal
end

puts "WINDOWS_BOOTSNAP_ENCODING_PASSED version=#{version} ruby=#{RUBY_VERSION} evaluations=16"
