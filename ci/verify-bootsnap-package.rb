# frozen_string_literal: true

require "digest"

root = ARGV.fetch(0)
path = File.join(root, "embedded/lib/ruby/gems/3.4.0/gems/bootsnap-1.26.0/lib/bootsnap/compile_cache/iseq.rb")
expected = "3c1264b97b557d54c309cb64149dca799fbd05cadba33acba303eb854d0ccc3e"
raise "Packaged Bootsnap correction missing or changed" unless Digest::SHA256.file(path).hexdigest == expected
puts "PACKAGED_BOOTSNAP_CORRECTION_VERIFIED sha256=#{expected}"
