# frozen_string_literal: true

require "yaml"
require "digest"

path = File.join(ENV.fetch("MSF_NOKOGIRI_SOURCE_CACHE"), "source-cache-use.yml")
receipt = YAML.safe_load_file(path, aliases: false)
expected = "3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8"
abort "Invalid cache receipt schema" unless receipt.fetch("schema") == 1
abort "Unexpected libiconv archive" unless receipt.fetch("archive") == "libiconv-1.18.tar.gz"
abort "Unexpected libiconv SHA-256" unless receipt.fetch("sha256") == expected
root = receipt.fetch("gem_directory")
abort "Receipt is not from embedded Nokogiri" unless root.match?(%r{\A[Cc]:/metasploit-framework/embedded/lib/ruby/gems/3\.4\.0/gems/nokogiri-1\.19\.4\z})
archive = File.join(root, "ports", "archives", receipt.fetch("archive"))
abort "Installed source archive differs" unless Digest::SHA256.file(archive).hexdigest == expected
abort "Receipt is not from Windows Ruby" unless receipt.fetch("ruby_platform").include?("mingw")
puts File.read(path)
puts "NOKOGIRI_PRODUCTION_SOURCE_CACHE_RECEIPT_VERIFIED"
