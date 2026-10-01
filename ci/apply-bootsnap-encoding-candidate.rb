# frozen_string_literal: true

# Disposable-runner diagnosis only. This does not change the built MSI.
require "digest"
require "json"

path = "D:/metasploit-framework/embedded/lib/ruby/gems/3.4.0/gems/bootsnap-1.26.0/lib/bootsnap/compile_cache/iseq.rb"
source = File.binread(path)
expected = "3c7da075a42441d09809421a6fdcfac1f25408ac5e27bdc8b5187bd80174862e"
raise "Unexpected Bootsnap source" unless Digest::SHA256.hexdigest(source) == expected
original = "::File.read(path, encoding: Encoding::UTF_8)"
replacement = "::File.read(path, external_encoding: Encoding::UTF_8, internal_encoding: nil)"
raise "Unexpected replacement count" unless source.scan(original).length == 1
corrected = source.sub(original, replacement)
File.binwrite(path, corrected)
raise "Candidate write differs" unless File.binread(path) == corrected
puts JSON.pretty_generate(original_sha256: expected,
  candidate_sha256: Digest::SHA256.hexdigest(corrected), ruby: RUBY_DESCRIPTION)
puts "BOOTSNAP_CANDIDATE_APPLIED_TO_DISPOSABLE_INSTALLATION"
