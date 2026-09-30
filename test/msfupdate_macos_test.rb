# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'tmpdir'

class MsfupdateMacOSTest < Minitest::Test
  TEMPLATE = File.expand_path('../config/templates/metasploit-framework-wrappers/msfupdate.erb', __dir__)

  def setup
    skip 'macOS package metadata tests require xmllint' unless File.executable?('/usr/bin/xmllint')

    @directory = Dir.mktmpdir('msf update test ')
    @tools = File.join(@directory, 'tools')
    @root = File.join(@directory, 'installation')
    @temp = File.join(@directory, 'downloads')
    @events = File.join(@directory, 'events.jsonl')
    @distribution = File.join(@directory, 'Distribution')
    FileUtils.mkdir_p([@tools, @temp, File.join(@root, 'embedded/bin')])
    File.write(File.join(@root, 'embedded/bin/ruby'), 'installed runtime sentinel')
    File.write(File.join(@root, 'configuration'), 'existing user configuration')
    distribution('arm64')
    %w[curl pkgutil installer file sysctl uname id sudo].each { |command| mock(command) }
    @environment = {
      'PATH' => "#{@tools}:/usr/bin:/bin:/usr/sbin:/sbin",
      'TMPDIR' => @temp,
      'TEST_EVENTS' => @events,
      'TEST_DISTRIBUTION' => @distribution,
      'TEST_INSTALL_ROOT' => @root,
      'TEST_HW_ARM' => '1',
      'TEST_INSTALLED_ARCHS' => 'arm64'
    }
    # Exercise the production function definitions without executing the
    # privileged platform dispatcher. Its sudo path is tested separately.
    definitions, dispatcher = File.read(TEMPLATE).split(/^DOWNLOAD_URI=/, 2)
    raise 'Updater dispatcher boundary was not found' unless dispatcher

    @driver = File.join(@directory, 'run update.sh')
    File.write(@driver, definitions + <<~SH)
      DOWNLOAD_URI=https://example.invalid/metasploit-framework
      install_pkg "$TEST_INSTALL_ROOT"
    SH
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory
  end

  def distribution(architectures)
    attribute = architectures.nil? ? '' : "hostArchitectures=\"#{architectures}\""
    File.write(@distribution, "<installer-gui-script><options #{attribute}/></installer-gui-script>")
  end

  def mock(command)
    script = File.join(@tools, command)
    File.write(script, "#!#{RbConfig.ruby}\n" + <<~'RUBY')
      require 'fileutils'
      require 'json'
      command = File.basename($PROGRAM_NAME)
      File.open(ENV.fetch('TEST_EVENTS'), 'a') { |file| file.puts(JSON.generate([command, ARGV])) }
      case command
      when 'sysctl'
        puts ENV.fetch('TEST_HW_ARM', '1')
      when 'uname'
        puts ARGV.include?('-m') ? ENV.fetch('TEST_UNAME', 'arm64') : 'Darwin test'
      when 'file'
        if ENV['TEST_FILE_DESCRIPTION']
          puts ENV['TEST_FILE_DESCRIPTION']
        else
          ENV.fetch('TEST_INSTALLED_ARCHS', 'arm64').split.each do |arch|
            puts "Mach-O 64-bit executable #{arch}"
          end
        end
        exit ENV.fetch('TEST_FILE_STATUS', '0').to_i
      when 'curl'
        destination = ARGV.fetch(ARGV.index('--output') + 1)
        directory = File.dirname(destination)
        File.open(ENV.fetch('TEST_EVENTS'), 'a') do |file|
          file.puts(JSON.generate(['download_directory', { 'path' => directory, 'mode' => File.stat(directory).mode & 0o777 }]))
        end
        File.write(destination, 'partially downloaded package')
        if ENV['TEST_WAIT_FOR_SIGNAL']
          File.write(ENV.fetch('TEST_DOWNLOAD_PID'), Process.pid.to_s)
          sleep 60
        end
        exit ENV.fetch('TEST_CURL_STATUS', '0').to_i
      when 'pkgutil'
        if ARGV.first == '--check-signature'
          exit ENV.fetch('TEST_SIGNATURE_STATUS', '0').to_i
        elsif ARGV.first == '--expand'
          exit ENV.fetch('TEST_EXPAND_STATUS', '0').to_i unless ENV.fetch('TEST_EXPAND_STATUS', '0') == '0'
          FileUtils.mkdir_p(ARGV.fetch(2))
          FileUtils.cp(ENV.fetch('TEST_DISTRIBUTION'), File.join(ARGV.fetch(2), 'Distribution'))
        else
          abort "Unexpected pkgutil arguments: #{ARGV.inspect}"
        end
      when 'installer'
        exit ENV.fetch('TEST_INSTALLER_STATUS', '0').to_i
      when 'id'
        puts ENV.fetch('TEST_UID', '0')
      when 'sudo'
        exit ENV.fetch('TEST_SUDO_STATUS', '0').to_i
      end
    RUBY
    File.chmod(0o755, script)
  end

  def events
    return [] unless File.exist?(@events)

    File.readlines(@events).map { |line| JSON.parse(line) }
  end

  def update(extra = {})
    output, error, status = Open3.capture3(@environment.merge(extra), '/bin/sh', @driver)
    assert_empty Dir.children(@temp), "Temporary files leaked: #{Dir.children(@temp)}"
    assert_download_cleanup
    assert_equal 'existing user configuration', File.read(File.join(@root, 'configuration'))
    [output + error, status.exitstatus]
  end

  def assert_download_cleanup
    events.select { |command, _| command == 'download_directory' }.each do |_, directory|
      refute File.exist?(directory.fetch('path')), "Temporary directory leaked: #{directory.fetch('path')}"
    end
  end

  def test_download_directory_ignores_inherited_user_tmpdir
    output, status = update
    assert_equal 0, status, output
    directory = events.assoc('download_directory').fetch(1)
    assert_equal '/private/tmp', File.dirname(directory.fetch('path'))
    assert_equal 0o700, directory.fetch('mode')
  end

  def test_download_command_rejects_non_https_transport
    output, status = update
    assert_equal 0, status, output
    arguments = events.assoc('curl').fetch(1).dup
    destination = File.join(@directory, 'unexpected-download')
    arguments[arguments.index('--output') + 1] = destination
    arguments[-1] = 'file:///dev/null'
    _, error, result = Open3.capture3('/usr/bin/curl', *arguments)
    refute result.success?, error
    refute File.exist?(destination)
  end

  def assert_not_installed
    refute events.any? { |command, _| command == 'installer' }, 'Installer must not run on failed verification'
  end

  def test_native_arm_update
    output, status = update
    assert_equal 0, status, output
    assert events.any? { |command, _| command == 'installer' }
  end

  def test_native_intel_update
    distribution('x86_64')
    output, status = update('TEST_HW_ARM' => '0', 'TEST_UNAME' => 'x86_64', 'TEST_INSTALLED_ARCHS' => 'x86_64')
    assert_equal 0, status, output
  end

  def test_rosetta_shell_preserves_native_installation
    output, status = update('TEST_UNAME' => 'x86_64')
    assert_equal 0, status, output
    assert_includes output, 'Installing arm64 package'
  end

  def test_existing_intel_installation_is_not_silently_migrated
    distribution('x86_64')
    output, status = update('TEST_INSTALLED_ARCHS' => 'x86_64')
    assert_equal 0, status, output
    assert_includes output, 'Installing x86_64 package'
  end

  def test_fresh_install_under_rosetta_uses_hardware_architecture
    File.unlink(File.join(@root, 'embedded/bin/ruby'))
    output, status = update('TEST_UNAME' => 'x86_64')
    assert_equal 0, status, output
    assert_includes output, 'Installing arm64 package'
  end

  def test_universal_installed_ruby_selects_native_architecture
    output, status = update('TEST_INSTALLED_ARCHS' => 'x86_64 arm64')
    assert_equal 0, status, output
    assert_includes output, 'Installing arm64 package'
  end

  def test_universal_package_is_compatible
    distribution('x86_64, arm64')
    output, status = update
    assert_equal 0, status, output
  end

  def test_rejects_wrong_package_architecture
    distribution('x86_64')
    output, status = update
    refute_equal 0, status
    assert_includes output, 'requires arm64'
    assert_not_installed
  end

  def test_rejects_missing_package_architecture
    distribution(nil)
    output, status = update
    refute_equal 0, status
    assert_includes output, "package for 'unknown'"
    assert_not_installed
  end

  def test_rejects_malformed_distribution
    File.write(@distribution, '<broken')
    _, status = update
    refute_equal 0, status
    assert_not_installed
  end

  def test_architecture_names_are_exact_tokens
    distribution('arm64e')
    _, status = update
    refute_equal 0, status
    assert_not_installed
  end

  def test_missing_download_never_reaches_signature_or_installer
    _, status = update('TEST_CURL_STATUS' => '22')
    assert_equal 22, status
    refute events.any? { |command, _| command == 'pkgutil' }
    assert_not_installed
  end

  def test_partial_download_never_reaches_signature_or_installer
    _, status = update('TEST_CURL_STATUS' => '18')
    assert_equal 18, status
    assert_not_installed
  end

  def test_signature_failure_never_installs
    _, status = update('TEST_SIGNATURE_STATUS' => '1')
    refute_equal 0, status
    assert_not_installed
  end

  def test_corrupt_package_never_installs
    _, status = update('TEST_EXPAND_STATUS' => '1')
    refute_equal 0, status
    assert_not_installed
  end

  def test_unknown_installed_ruby_never_downloads
    _, status = update('TEST_FILE_STATUS' => '1')
    refute_equal 0, status
    refute events.any? { |command, _| command == 'curl' }
    assert_not_installed
  end

  def test_non_executable_and_unknown_architectures_never_download
    ['ASCII text', 'Mach-O 64-bit object arm64', 'Mach-O 64-bit executable arm64e'].each do |description|
      _, status = update('TEST_FILE_DESCRIPTION' => description)
      refute_equal 0, status, description
      refute events.any? { |command, _| command == 'curl' }
      assert_not_installed
    end
  end

  def test_real_executables_are_inspected_without_running_developer_tools
    source = File.join(@directory, 'main.c')
    File.write(source, 'int main(void) { return 0; }')
    binaries = %w[arm64 x86_64].to_h do |arch|
      path = File.join(@directory, "ruby-#{arch}")
      output, status = Open3.capture2e('/usr/bin/clang', '-arch', arch, source, '-o', path)
      assert status.success?, output
      [arch, path]
    end
    universal = File.join(@directory, 'ruby-universal')
    output, status = Open3.capture2e('/usr/bin/lipo', '-create', *binaries.values, '-output', universal)
    assert status.success?, output

    File.unlink(File.join(@tools, 'file'))
    # These tools are used only to make fixtures, never by the updater.
    %w[lipo clang xcrun].each do |tool|
      path = File.join(@tools, tool)
      File.write(path, "#!/bin/sh\necho 'Unexpected developer tool' >&2\nexit 99\n")
      File.chmod(0o755, path)
    end
    [[binaries.fetch('arm64'), 'arm64'], [binaries.fetch('x86_64'), 'x86_64'], [universal, 'arm64']].each do |binary, arch|
      FileUtils.cp(binary, File.join(@root, 'embedded/bin/ruby'))
      distribution(arch)
      output, status = update
      assert_equal 0, status, output
      assert_includes output, "Installing #{arch} package"
    end
  end

  def test_installer_failure_is_reported
    _, status = update('TEST_INSTALLER_STATUS' => '7')
    assert_equal 7, status
  end

  def test_sudo_failure_is_reported_and_arguments_preserved
    _, _, status = Open3.capture3(@environment.merge('TEST_UID' => '501', 'TEST_SUDO_STATUS' => '9'), '/bin/sh', TEMPLATE, 'argument with spaces')
    assert_equal 9, status.exitstatus
    assert_includes events, ['sudo', ['-E', TEMPLATE, 'argument with spaces']]
  end

  def test_download_interruption_cleans_up_without_installing
    pid_file = File.join(@directory, 'download.pid')
    env = @environment.merge('TEST_WAIT_FOR_SIGNAL' => '1', 'TEST_DOWNLOAD_PID' => pid_file)
    Open3.popen3(env, '/bin/sh', @driver, pgroup: true) do |input, output, error, process|
      input.close
      begin
        Timeout.timeout(10) do
          sleep 0.02 until File.exist?(pid_file)
          Process.kill('TERM', -process.pid)
          refute process.value.success?
          output.read
          error.read
        end
      ensure
        if process.alive?
          Process.kill('KILL', -process.pid)
          process.join
        end
      end
    end
    assert_empty Dir.children(@temp)
    assert_download_cleanup
    assert_not_installed
    download_pid = Integer(File.read(pid_file))
    assert_raises(Errno::ESRCH) { Process.kill(0, download_pid) }
  end
end
