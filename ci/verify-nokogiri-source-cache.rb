# frozen_string_literal: true

require "yaml"
require "digest"

module NokogiriSourceCacheReceipt
  def self.verify(cache_dir, gem_directory:, sha256:, ruby_platform:)
    receipt = YAML.safe_load_file(File.join(cache_dir, "source-cache-use.yml"), aliases: false)
    raise "Invalid cache receipt schema" unless receipt.fetch("schema") == 1
    raise "Unexpected libiconv archive" unless receipt.fetch("archive") == "libiconv-1.18.tar.gz"
    raise "Unexpected libiconv SHA-256" unless receipt.fetch("sha256") == sha256
    unless receipt.fetch("gem_directory").casecmp?(gem_directory.tr("\\", "/"))
      raise "Receipt is not from expected embedded Nokogiri"
    end
    raise "Unexpected build platform" unless receipt.fetch("ruby_platform") == ruby_platform
    dependency = YAML.safe_load_file(File.join(gem_directory, "dependencies.yml"), aliases: false).fetch("libiconv")
    unless dependency.fetch("version") == "1.18" && dependency.fetch("sha256") == sha256
      raise "Installed Nokogiri dependency differs"
    end
    # Nokogiri removes ports/archives after compilation. The receipt attests to
    # staging there; rehash the retained source cache, not the cleaned directory.
    archive = File.join(cache_dir, receipt.fetch("archive"))
    raise "Retained source archive differs" unless Digest::SHA256.file(archive).hexdigest == sha256
    receipt
  end
end

if $PROGRAM_NAME == __FILE__
  receipt = NokogiriSourceCacheReceipt.verify(ENV.fetch("MSF_NOKOGIRI_SOURCE_CACHE"),
    gem_directory: "C:/metasploit-framework/embedded/lib/ruby/gems/3.4.0/gems/nokogiri-1.19.4",
    sha256: "3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8",
    ruby_platform: "x64-mingw-ucrt")
  puts YAML.dump(receipt)
  puts "NOKOGIRI_PRODUCTION_SOURCE_CACHE_RECEIPT_VERIFIED"
end
