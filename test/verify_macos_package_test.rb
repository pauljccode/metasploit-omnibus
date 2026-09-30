# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'
require_relative '../scripts/verify_macos_package'

# Use real Mach-O fixtures and Apple's tools: command-output mocks would not
# catch mistakes in architecture selection or dependency load-command parsing.
class MacOSPackageVerifierTest < Minitest::Test
  def setup
    skip 'Mach-O integration tests require macOS and Xcode command line tools' unless RUBY_PLATFORM.include?('darwin')

    @directory = Dir.mktmpdir('macos package test ')
    @root = File.join(@directory, 'package')
    @bin = File.join(@root, 'embedded/bin')
    @lib = File.join(@root, 'embedded/lib')
    FileUtils.mkdir_p([@bin, @lib])
    compile(File.join(@bin, 'ruby'), source: 'int main(void) { return 0; }', executable: true)
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory
  end

  def compile(path, architecture: 'arm64', source: 'int fixture(void) { return 0; }', executable: false, install_name: nil, dependency: nil, rpath: nil)
    FileUtils.mkdir_p(File.dirname(path))
    input = File.join(@directory, 'fixture.c')
    File.write(input, source)
    args = ['/usr/bin/clang', '-target', "#{architecture}-apple-macos14", input, '-o', path]
    args << '-dynamiclib' unless executable
    args.concat(['-Xlinker', '-install_name', '-Xlinker', install_name]) if install_name
    args.concat(['-Xlinker', '-needed_library', '-Xlinker', dependency]) if dependency
    args.concat(['-Xlinker', '-rpath', '-Xlinker', rpath]) if rpath
    output, error, status = Open3.capture3(*args)
    assert status.success?, "Fixture compilation failed: #{output}\n#{error}"
    path
  end

  def verify(architecture = 'arm64')
    MacOSPackageVerifier.new(@root, architecture).verify!(runtime: false)
  end

  def test_native_package_with_spaces_in_its_path
    compile(File.join(@lib, 'native library.dylib'))
    assert_equal 2, verify
  end

  def test_intel_package_remains_supported
    compile(File.join(@bin, 'ruby'), architecture: 'x86_64', executable: true, source: 'int main(void) { return 0; }')
    compile(File.join(@lib, 'intel.dylib'), architecture: 'x86_64')
    assert_equal 2, verify('x86_64')
  end

  def test_rejects_intel_library_in_arm_package
    path = compile(File.join(@lib, 'wrong.dylib'), architecture: 'x86_64')
    error = assert_raises(MacOSPackageVerifier::VerificationError) { verify }
    assert_includes error.message, path
    assert_includes error.message, 'arm64'
  end

  def test_rejects_arm64_library_built_for_ios
    path = compile(File.join(@lib, 'wrong-platform.dylib'))
    _, error, status = Open3.capture3('/usr/bin/vtool', '-set-build-version', 'ios', '14.0', '14.0', '-replace', '-output', path, path)
    assert status.success?, error
    error = assert_raises(MacOSPackageVerifier::VerificationError) { verify }
    assert_includes error.message, 'not built for macOS'
  end

  def test_accepts_legacy_macos_version_load_command
    path = compile(File.join(@lib, 'legacy.dylib'))
    _, error, status = Open3.capture3('/usr/bin/vtool', '-set-version-min', 'macos', '10.15', '10.15', '-replace', '-output', path, path)
    assert status.success?, error
    assert_equal 2, verify
  end

  def test_packaged_ruby_must_be_an_executable
    compile(File.join(@bin, 'ruby'))
    error = assert_raises(MacOSPackageVerifier::VerificationError) { verify }
    assert_includes error.message, 'Ruby is not an executable'
  end

  def test_universal_host_library_supplies_expected_slice
    arm = compile(File.join(@directory, 'arm.dylib'))
    intel = compile(File.join(@directory, 'intel.dylib'), architecture: 'x86_64')
    _, error, status = Open3.capture3('/usr/bin/lipo', '-create', arm, intel, '-output', File.join(@lib, 'universal.dylib'))
    assert status.success?, error
    assert_equal 2, verify
  end

  def test_rejects_missing_transitive_library
    dependency = compile(File.join(@lib, 'dependency.dylib'), install_name: '@loader_path/dependency.dylib')
    compile(File.join(@lib, 'consumer.dylib'), dependency: dependency)
    File.unlink(dependency)
    error = assert_raises(MacOSPackageVerifier::VerificationError) { verify }
    assert_includes error.message, 'dependency.dylib'
  end

  def test_rejects_a_dependency_replaced_with_an_object_file
    dependency = compile(File.join(@lib, 'dependency.dylib'), install_name: '@loader_path/dependency.dylib')
    compile(File.join(@lib, 'consumer.dylib'), dependency: dependency)
    _, error, status = Open3.capture3('/usr/bin/clang', '-target', 'arm64-apple-macos14', '-c', File.join(@directory, 'fixture.c'), '-o', dependency)
    assert status.success?, error
    error = assert_raises(MacOSPackageVerifier::VerificationError) { verify }
    assert_includes error.message, 'Not a loadable host image'
  end

  def test_rejects_a_transitive_dependency_that_is_not_macho
    path = File.join(@lib, 'dependency-without-extension')
    dependency = compile(File.join(@lib, 'dependency.dylib'), install_name: path)
    compile(File.join(@lib, 'consumer.dylib'), dependency: dependency)
    File.write(path, 'not a dynamic library')
    error = assert_raises(MacOSPackageVerifier::VerificationError) { verify }
    assert_includes error.message, 'not Mach-O'
  end

  def test_resolves_loader_relative_dependencies
    dependency = compile(File.join(@lib, 'dependency.dylib'), install_name: '@loader_path/dependency.dylib')
    compile(File.join(@lib, 'consumer.dylib'), dependency: dependency)
    assert_equal 3, verify
  end

  def test_resolves_executable_relative_dependencies
    dependency = compile(File.join(@lib, 'dependency.dylib'), install_name: '@executable_path/../lib/dependency.dylib')
    compile(File.join(@bin, 'consumer'), dependency: dependency, executable: true, source: 'int main(void) { return 0; }')
    assert_equal 3, verify
  end

  def test_resolves_rpath_dependencies
    dependency = compile(File.join(@lib, 'dependency.dylib'), install_name: '@rpath/dependency.dylib')
    compile(File.join(@lib, 'consumer.dylib'), dependency: dependency, rpath: '@loader_path')
    assert_equal 3, verify
  end

  def test_rpath_is_inherited_from_the_loading_executable
    dependency = compile(File.join(@lib, 'dependency.dylib'), install_name: '@rpath/dependency.dylib')
    consumer = compile(File.join(@lib, 'consumer.dylib'), install_name: '@rpath/consumer.dylib', dependency: dependency)
    compile(File.join(@bin, 'ruby'), executable: true, source: 'int main(void) { return 0; }', dependency: consumer, rpath: '@executable_path/../lib')
    assert_equal 3, verify
  end

  def test_dlopen_library_uses_ruby_rpaths
    dependency = compile(File.join(@lib, 'dependency.dylib'), install_name: '@rpath/dependency.dylib')
    compile(File.join(@lib, 'consumer.bundle'), dependency: dependency)
    compile(File.join(@bin, 'ruby'), executable: true, source: 'int main(void) { return 0; }', rpath: '@executable_path/../lib')
    assert_equal 3, verify
  end

  def test_rejects_unresolved_rpath
    dependency = compile(File.join(@lib, 'dependency.dylib'), install_name: '@rpath/dependency.dylib')
    compile(File.join(@lib, 'consumer.dylib'), dependency: dependency)
    error = assert_raises(MacOSPackageVerifier::VerificationError) { verify }
    assert_includes error.message, 'Unresolved dependency'
  end

  def test_rejects_build_machine_library_even_when_it_exists
    dependency = compile(File.join(@directory, 'outside.dylib'))
    compile(File.join(@lib, 'consumer.dylib'), dependency: dependency)
    error = assert_raises(MacOSPackageVerifier::VerificationError) { verify }
    assert_includes error.message, 'escapes package'
  end

  def test_rejects_library_symlink_escaping_package
    dependency = compile(File.join(@directory, 'outside.dylib'))
    File.symlink(dependency, File.join(@lib, 'external.dylib'))
    error = assert_raises(MacOSPackageVerifier::VerificationError) { verify }
    assert_includes error.message, 'escapes package'
  end

  def test_rejects_directory_symlink_escaping_package
    external = File.join(@directory, 'outside')
    compile(File.join(external, 'external.dylib'))
    File.symlink(external, File.join(@lib, 'external'))
    error = assert_raises(MacOSPackageVerifier::VerificationError) { verify }
    assert_includes error.message, 'escapes package'
  end

  def test_rejects_broken_library_symlink
    File.symlink('missing.dylib', File.join(@lib, 'external.dylib'))
    assert_raises(MacOSPackageVerifier::VerificationError) { verify }
  end

  def test_foreign_target_payloads_are_not_host_roots
    payload = File.join(@lib, 'ruby/gems/3.4.0/gems/metasploit_payloads-mettle-1.0.48/build/x86_64-apple-darwin/bin/mettle.dylib')
    compile(payload, architecture: 'x86_64')
    assert_equal 1, verify
  end

  def test_payload_exclusion_does_not_hide_a_loaded_host_dependency
    payload = File.join(@lib, 'ruby/gems/3.4.0/gems/metasploit_payloads-mettle-1.0.48/build/x86_64-apple-darwin/bin/mettle.dylib')
    compile(payload, architecture: 'x86_64')
    # Use an install-name rewrite so the linker does not reject the mixed-arch
    # fixture before the package verifier gets to inspect it.
    dependency = compile(File.join(@lib, 'dependency.dylib'), install_name: payload)
    compile(File.join(@lib, 'consumer.dylib'), dependency: dependency)
    error = assert_raises(MacOSPackageVerifier::VerificationError) { verify }
    assert_includes error.message, payload
  end

  def test_rejects_non_macho_host_library
    File.write(File.join(@lib, 'broken.bundle'), 'not a shared library')
    error = assert_raises(MacOSPackageVerifier::VerificationError) { verify }
    assert_includes error.message, 'not Mach-O'
  end

  def test_library_symlink_cannot_hide_a_non_macho_target
    File.write(File.join(@lib, 'plain-text'), 'not a shared library')
    File.symlink('plain-text', File.join(@lib, 'broken.bundle'))
    error = assert_raises(MacOSPackageVerifier::VerificationError) { verify }
    assert_includes error.message, 'not Mach-O'
  end

  def test_rejects_missing_ruby
    File.unlink(File.join(@bin, 'ruby'))
    assert_raises(MacOSPackageVerifier::VerificationError) { verify }
  end

  def test_runtime_probe_rejects_an_executable_that_is_not_ruby
    architecture = RbConfig::CONFIG.fetch('host_cpu')
    compile(File.join(@bin, 'ruby'), architecture: architecture, executable: true, source: 'int main(void) { return 0; }')
    error = assert_raises(MacOSPackageVerifier::VerificationError) do
      MacOSPackageVerifier.new(@root, architecture).verify!
    end
    assert_includes error.message, "Packaged Ruby is not running as #{architecture}"
  end
end
