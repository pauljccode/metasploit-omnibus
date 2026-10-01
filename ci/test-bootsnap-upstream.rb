# frozen_string_literal: true

require "open3"
require "fileutils"
require "rbconfig"

checkout, patch_root, log_directory = ARGV.map { |path| File.expand_path(path) }
FileUtils.mkdir_p(log_directory)
Dir.chdir(checkout)

def run_logged(log_directory, name, *command)
  output, status = Open3.capture2e(*command)
  File.binwrite(File.join(log_directory, "#{name}.log"), output)
  puts output
  status
end

regression = File.join(patch_root, "ci/bootsnap-source-encoding-regression.patch")
correction = File.join(patch_root, "config/patches/metasploit-framework/bootsnap-1.26.0-source-encoding.patch")
raise "Regression patch failed" unless system("git", "apply", "--check", regression) && system("git", "apply", regression)
raise "Original extension compilation failed" unless run_logged(log_directory, "compile", "bundle", "exec", "rake", "compile").success?
status = run_logged(log_directory, "original-regression", "bundle", "exec", "ruby", "-Itest", "test/compile_cache/iseq_cache_test.rb",
  "--name", "test_source_encoding_does_not_depend_on_default_internal")
original = File.binread(File.join(log_directory, "original-regression.log"))
unless !status.success? && original.include?("Encoding::UndefinedConversionError") &&
    original.match?(/1 runs, \d+ assertions, 0 failures, 1 errors, 0 skips/)
  raise "Original source did not reproduce the expected encoding regression"
end
puts "BOOTSNAP_UPSTREAM_REGRESSION_REPRODUCED"
raise "Correction patch failed" unless system("git", "apply", "--check", correction) && system("git", "apply", correction)
raise "Corrected upstream suite failed" unless run_logged(log_directory, "corrected-suite", "bundle", "exec", "rake").success?
puts "BOOTSNAP_UPSTREAM_FULL_SUITE_PASSED #{RUBY_DESCRIPTION}"
