# frozen_string_literal: true

require "digest"
require "json"

root = ARGV.fetch(0)
manifest = JSON.parse(File.read(File.join(__dir__, "database-recovery-sources.json")))
manifest.fetch("files").each do |relative_path, expected|
  path = File.join(root, "embedded/framework", relative_path)
  raise "Packaged PostgreSQL recovery source changed: #{relative_path}" unless Digest::SHA256.file(path).hexdigest == expected
end
puts "PACKAGED_POSTGRESQL_RECOVERY_VERIFIED framework=#{manifest.fetch('framework_commit')}"
