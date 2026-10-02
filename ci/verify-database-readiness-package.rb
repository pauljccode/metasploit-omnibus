# frozen_string_literal: true

require "digest"

root = ARGV.fetch(0)
path = File.join(root, "embedded/framework/lib/msfdb_helpers/pg_ctl.rb")
expected = "6bf496a09dd8bbef8da1ea1e483640a03c6677e9f40d6b3e70d5c69c6eecf83a"
raise "Packaged PostgreSQL readiness correction missing or changed" unless Digest::SHA256.file(path).hexdigest == expected
puts "PACKAGED_POSTGRESQL_READINESS_VERIFIED sha256=#{expected}"
