#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'set'

# Verify the installed host runtime, including gems loaded with dlopen. Payload
# binaries shipped for other target platforms are deliberately not host roots.
class MacOSPackageVerifier
  class VerificationError < StandardError; end

  MACHO_MAGICS = %w[feedface feedfacf cefaedfe cffaedfe cafebabe bebafeca cafebabf bfbafeca].freeze
  PAYLOAD_DIRECTORIES = %r{\Aembedded/lib/ruby/gems/[^/]+/gems/(?:metasploit_payloads-mettle-[^/]+/build|metasploit-payloads-[^/]+/data)(?:/|\z)}
  LOAD_COMMANDS = %w[LC_LOAD_DYLIB LC_LOAD_WEAK_DYLIB LC_REEXPORT_DYLIB LC_LOAD_UPWARD_DYLIB LC_LAZY_LOAD_DYLIB].freeze

  attr_reader :checked_images

  def initialize(root, architecture)
    raise VerificationError, "Unsupported architecture: #{architecture}" unless %w[arm64 x86_64].include?(architecture)

    @root = File.realpath(root)
    @architecture = architecture
    @checked_images = Set.new
    @image_cache = {}
  end

  def verify!(runtime: true)
    ruby = File.join(@root, 'embedded/bin/ruby')
    raise VerificationError, "Missing packaged Ruby: #{ruby}" unless File.file?(ruby)

    roots = host_images
    raise VerificationError, 'Packaged Ruby is not Mach-O' unless roots.include?(File.realpath(ruby))
    raise VerificationError, 'Packaged Ruby is not an executable' unless image(File.realpath(ruby))[:filetype] == 'EXECUTE'

    executables, libraries = roots.partition { |path| path.start_with?(File.join(@root, 'embedded/bin/')) }
    executables.each { |path| verify_dependencies(path, path, [], Set.new) }
    ruby_rpaths = image(ruby)[:rpaths].map { |entry| expand_path(entry, ruby, ruby) }
    libraries.each do |path|
      # Already loaded libraries have been checked in their executable's run
      # path context. Remaining roots include Ruby's dlopen-loaded extensions.
      next if @checked_images.include?(path)

      verify_dependencies(path, ruby, ruby_rpaths, Set.new)
    end
    verify_ruby(ruby) if runtime
    @checked_images.length
  end

  private

  def run(*arguments)
    output, error, status = Open3.capture3(*arguments)
    raise VerificationError, "#{arguments.join(' ')} failed: #{error.strip}" unless status.success?

    output
  end

  def contained_path(path)
    real = File.realpath(path)
    unless real.start_with?("#{@root}/")
      raise VerificationError, "Host dependency escapes package: #{path} -> #{real}"
    end
    real
  rescue Errno::ENOENT, Errno::ELOOP => error
    raise VerificationError, "Missing or invalid host dependency: #{path} (#{error.message})"
  end

  def macho?(path)
    MACHO_MAGICS.include?(File.binread(path, 4).unpack1('H*'))
  end

  def host_images
    images = Set.new
    visited = Set.new
    directories = %w[embedded/bin embedded/lib].map { |path| File.join(@root, path) }
    until directories.empty?
      directory = contained_path(directories.pop)
      next unless visited.add?(directory)

      Dir.children(directory).sort.each do |name|
        path = File.join(directory, name)
        relative = path.delete_prefix("#{@root}/")
        next if PAYLOAD_DIRECTORIES.match?(relative) || name.end_with?('.dSYM')

        path = contained_path(path)
        if File.directory?(path)
          directories << path
        elsif File.file?(path)
          library = [relative, path].any? { |entry| %w[.bundle .dylib .so].include?(File.extname(entry)) }
          binary = relative.start_with?('embedded/bin/')
          next unless library || binary

          if macho?(path)
            images << path
          elsif library
            raise VerificationError, "Host library is not Mach-O: #{path}"
          end
        end
      end
    end
    images
  end

  def image(path)
    @image_cache[path] ||= begin
      raise VerificationError, "Host dependency is not Mach-O: #{path}" unless macho?(path)

      run('/usr/bin/lipo', path, '-verify_arch', @architecture)
      output = run('/usr/bin/otool', '-arch', @architecture, '-hv', '-l', path)
      header = output.lines.find { |line| line.split.first == 'MH_MAGIC_64' }
      filetype = header&.split&.fetch(4, nil)
      unless %w[EXECUTE DYLIB BUNDLE].include?(filetype)
        raise VerificationError, "Not a loadable host image: #{path} (#{filetype || 'unknown file type'})"
      end
      platforms = output.scan(/^\s*platform (\S+)\s*$/).flatten
      legacy_macos = output.match?(/^\s*cmd LC_VERSION_MIN_MACOSX\s*$/)
      unless platforms == ['MACOS'] || (platforms.empty? && legacy_macos)
        raise VerificationError, "Host image is not built for macOS: #{path} (#{platforms.join(', ')})"
      end
      dependencies = []
      rpaths = []
      command = nil
      output.each_line do |line|
        if (match = line.match(/^\s*cmd (LC_\w+)\s*$/))
          command = match[1]
        elsif LOAD_COMMANDS.include?(command) && (match = line.match(/^\s*name (.+) \(offset \d+\)\s*$/))
          dependencies << match[1]
        elsif command == 'LC_RPATH' && (match = line.match(/^\s*path (.+) \(offset \d+\)\s*$/))
          rpaths << match[1]
        end
      end
      @checked_images << path
      { dependencies: dependencies, rpaths: rpaths, filetype: filetype }
    end
  end

  def system_library?(path)
    # Modern macOS keeps system libraries in the dyld shared cache. They need
    # not exist as individual files on either the builder or the test runner.
    clean = File.expand_path(path)
    clean.start_with?('/usr/lib/', '/System/Library/')
  end

  def expand_path(path, loader, executable)
    case path
    when %r{\A@loader_path(?:/|\z)}
      File.expand_path(path.delete_prefix('@loader_path').delete_prefix('/'), File.dirname(loader))
    when %r{\A@executable_path(?:/|\z)}
      File.expand_path(path.delete_prefix('@executable_path').delete_prefix('/'), File.dirname(executable))
    when %r{\A/}
      path
    else
      raise VerificationError, "Unsupported library path #{path.inspect} in #{loader}"
    end
  end

  def verify_dependencies(path, executable, inherited_rpaths, visited)
    path = contained_path(path)
    info = image(path)
    own_rpaths = info[:rpaths].map { |entry| expand_path(entry, path, executable) }
    rpaths = (own_rpaths + inherited_rpaths).uniq
    return unless visited.add?([path, executable, rpaths])

    info[:dependencies].each do |dependency|
      if dependency.start_with?('@rpath/')
        suffix = dependency.delete_prefix('@rpath/')
        resolved = rpaths.map { |base| File.expand_path(suffix, base) }.find { |candidate| File.file?(candidate) || system_library?(candidate) }
        raise VerificationError, "Unresolved dependency #{dependency} in #{path}" unless resolved
      else
        resolved = expand_path(dependency, path, executable)
      end
      next if system_library?(resolved)

      verify_dependencies(resolved, executable, rpaths, visited)
    end
  end

  def verify_ruby(ruby)
    environment = { 'RUBYOPT' => nil, 'RUBYLIB' => nil, 'GEM_HOME' => nil, 'GEM_PATH' => nil }
    ENV.each_key { |key| environment[key] = nil if key.start_with?('DYLD_') }
    probe = 'puts RUBY_PLATFORM; puts RbConfig::CONFIG.fetch("host_cpu")'
    output = run(environment, ruby, '--disable=gems', '-rrbconfig', '-e', probe)
    platform, cpu = output.lines.map(&:strip)
    unless platform&.start_with?("#{@architecture}-darwin") && cpu == @architecture
      raise VerificationError, "Packaged Ruby is not running as #{@architecture}: #{output.strip}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { root: '/opt/metasploit-framework', runtime: true }
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: verify_macos_package.rb --arch arm64|x86_64 [--root DIRECTORY] [--static-only]'
    opts.on('--arch ARCH', 'Expected host architecture (required)') { |value| options[:arch] = value }
    opts.on('--root DIRECTORY', 'Installed package or expanded Payload directory') { |value| options[:root] = value }
    opts.on('--static-only', 'Inspect binaries without executing packaged Ruby') { options[:runtime] = false }
  end
  begin
    parser.parse!
    raise OptionParser::MissingArgument, '--arch' unless options[:arch]
    raise OptionParser::InvalidArgument, ARGV.join(' ') unless ARGV.empty?

    verifier = MacOSPackageVerifier.new(options[:root], options[:arch])
    count = verifier.verify!(runtime: options[:runtime])
    puts "Verified #{count} host Mach-O images for #{options[:arch]}#{options[:runtime] ? ' and native Ruby startup' : ' (static only)'}"
  rescue MacOSPackageVerifier::VerificationError, OptionParser::ParseError, SystemCallError => error
    warn error.message
    exit 1
  end
end
