# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "nokogiri-archive-cache"

class NokogiriArchiveCacheTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("nokogiri-cache-test")
    @gem_dir = File.join(@root, "gem")
    @cache = File.join(@root, "cache")
    FileUtils.mkdir_p([@gem_dir, @cache])
    @bytes = "verified source fixture\x00\xff".b
    @checksum = Digest::SHA256.hexdigest(@bytes)
    @source = File.join(@cache, "libiconv-1.18.tar.gz")
    @destination = File.join(@gem_dir, "ports/archives/libiconv-1.18.tar.gz")
    File.binwrite(@source, @bytes)
    dependency
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def dependency(version = "1.18", checksum = @checksum)
    File.write(File.join(@gem_dir, "dependencies.yml"),
      { "libiconv" => { "version" => version, "sha256" => checksum } }.to_yaml)
  end

  def test_verified_cache_is_copied_without_changing_gem_metadata
    original = File.binread(File.join(@gem_dir, "dependencies.yml"))
    capture_io { NokogiriArchiveCache.seed(@gem_dir, @cache) }
    assert_equal @bytes, File.binread(@destination)
    assert_equal original, File.binread(File.join(@gem_dir, "dependencies.yml"))
    assert_empty Dir.glob(File.join(File.dirname(@destination), ".libiconv-*"))
  end

  def test_corrupt_cache_is_rejected_before_destination_creation
    File.binwrite(@source, "wrong")
    assert_raises(RuntimeError) { NokogiriArchiveCache.seed(@gem_dir, @cache) }
    refute File.exist?(@destination)
  end

  def test_changed_dependency_checksum_is_not_overridden
    dependency("1.18", "0" * 64)
    assert_raises(RuntimeError) { NokogiriArchiveCache.seed(@gem_dir, @cache) }
    refute File.exist?(@destination)
  end

  def test_missing_archive_is_not_silently_downloaded
    File.unlink(@source)
    assert_raises(Errno::ENOENT) { NokogiriArchiveCache.seed(@gem_dir, @cache) }
  end

  def test_invalid_dependency_paths_and_checksums_are_rejected
    [["../../escape", @checksum], ["1.18", "invalid"]].each do |version, checksum|
      dependency(version, checksum)
      assert_raises(RuntimeError) { NokogiriArchiveCache.seed(@gem_dir, @cache) }
    end
  end

  def test_existing_corrupt_archive_is_not_overwritten
    FileUtils.mkdir_p(File.dirname(@destination))
    File.binwrite(@destination, "wrong")
    assert_raises(RuntimeError) { NokogiriArchiveCache.seed(@gem_dir, @cache) }
    assert_equal "wrong", File.binread(@destination)
  end

  def test_verified_existing_archive_can_be_reused
    2.times { capture_io { NokogiriArchiveCache.seed(@gem_dir, @cache) } }
    assert_equal @bytes, File.binread(@destination)
  end

  def test_hook_seeds_before_delegating_and_leaves_other_gems_alone
    old_cache = ENV["MSF_NOKOGIRI_SOURCE_CACHE"]
    base = Class.new do
      attr_accessor :gem_dir, :spec, :observed_archive
      def build_extensions
        self.observed_archive = Dir.glob(File.join(gem_dir, "ports/archives/*"))
        :compiled
      end
    end
    base.prepend(NokogiriArchiveCache)
    installer = base.new
    installer.gem_dir = @gem_dir
    installer.spec = Struct.new(:name).new("other")
    assert_equal :compiled, installer.build_extensions
    assert_empty installer.observed_archive
    installer.spec.name = "nokogiri"
    ENV["MSF_NOKOGIRI_SOURCE_CACHE"] = @cache
    capture_io { assert_equal :compiled, installer.build_extensions }
    assert_equal [@destination], installer.observed_archive
  ensure
    ENV["MSF_NOKOGIRI_SOURCE_CACHE"] = old_cache
  end

  def test_real_gem_installer_keeps_the_cache_through_extraction
    old_cache = ENV["MSF_NOKOGIRI_SOURCE_CACHE"]
    ENV["MSF_NOKOGIRI_SOURCE_CACHE"] = @cache
    FileUtils.mkdir_p(File.join(@gem_dir, "ext"))
    File.write(File.join(@gem_dir, "ext/extconf.rb"), <<~RUBY)
      require "digest"
      archive = File.expand_path("../ports/archives/libiconv-1.18.tar.gz", __dir__)
      abort "archive not staged before compilation" unless Digest::SHA256.file(archive).hexdigest == #{@checksum.inspect}
      File.write("Makefile", "all:\\ninstall:\\n")
    RUBY
    specification = Gem::Specification.new do |gem|
      gem.name = "nokogiri"
      gem.version = "0.0.0.cache.test"
      gem.summary = "Installer ordering fixture"
      gem.authors = ["Test fixture"]
      gem.license = "MIT"
      gem.homepage = "https://example.com"
      gem.files = ["dependencies.yml", "ext/extconf.rb"]
      gem.extensions = ["ext/extconf.rb"]
    end
    installed = nil
    capture_io do
      archive = Dir.chdir(@gem_dir) { Gem::Package.build(specification) }
      installed = Gem::Installer.at(File.join(@gem_dir, archive),
        install_dir: File.join(@root, "installed"), ignore_dependencies: true).install
    end
    assert File.exist?(installed.gem_build_complete_path)
    assert_equal @bytes, File.binread(File.join(installed.full_gem_path, "ports/archives/libiconv-1.18.tar.gz"))
  ensure
    ENV["MSF_NOKOGIRI_SOURCE_CACHE"] = old_cache
  end
end
