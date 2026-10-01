# frozen_string_literal: true

require "digest"
require "fileutils"
require "rubygems/installer"
require "tempfile"

# Build-only source cache for released Nokogiri gems that predate the mirror
# option in https://github.com/sparklemotion/nokogiri/pull/3671. No gem source,
# dependency version, checksum, or MiniPortile download behavior is changed.
module NokogiriArchiveCache
  def self.seed(gem_dir, cache_dir)
    require "yaml"
    dependency = YAML.safe_load_file(File.join(gem_dir, "dependencies.yml"), aliases: false).fetch("libiconv")
    version = dependency.fetch("version")
    checksum = dependency.fetch("sha256")
    unless version.is_a?(String) && version.match?(/\A\d+(?:\.\d+)+\z/) &&
        checksum.is_a?(String) && checksum.match?(/\A[0-9a-f]{64}\z/)
      raise "Invalid Nokogiri libiconv dependency identity"
    end

    filename = "libiconv-#{version}.tar.gz"
    source = File.join(cache_dir, filename)
    verify(source, checksum)
    archives = File.join(gem_dir, "ports", "archives")
    destination = File.join(archives, filename)
    if File.exist?(destination)
      verify(destination, checksum)
    else
      FileUtils.mkdir_p(archives)
      Tempfile.create([".libiconv-", ".tmp"], archives) do |temporary|
        temporary.binmode
        File.open(source, "rb") { |input| IO.copy_stream(input, temporary) }
        temporary.flush
        verify(temporary.path, checksum)
        temporary.close
        File.rename(temporary.path, destination)
      end
    end
    puts "NOKOGIRI_SOURCE_CACHE_VERIFIED #{filename} sha256=#{checksum}"
  end

  def self.verify(path, checksum)
    raise "Nokogiri source cache checksum mismatch: #{path}" unless Digest::SHA256.file(path).hexdigest == checksum
  end

  def build_extensions
    if spec.name == "nokogiri"
      NokogiriArchiveCache.seed(gem_dir, ENV.fetch("MSF_NOKOGIRI_SOURCE_CACHE"))
    end
    super
  end
end

# RubyGems removes the gem directory before extracting it. Seed after extraction,
# immediately before compilation; Bundler's installer delegates this method to
# RubyGems for uncached native extensions. MiniPortile verifies again on extract.
Gem::Installer.prepend(NokogiriArchiveCache)
