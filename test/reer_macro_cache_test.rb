# Created by yuxilong on 2026/10/28.
require 'minitest/autorun'
require 'tmpdir'
require_relative '../scripts/reer_macro_cache'
require 'cocoapods'
require_relative '../lib/cocoapods-publish/reer_macro_preparation'

class ReerMacroCacheTest < Minitest::Test
  def setup
    root = File.expand_path('../.tmp', __dir__)
    FileUtils.mkdir_p(root)
    @directory = Dir.mktmpdir('macro-cache-', root)
    @environment = ENV.to_h
    bin = File.join(@directory, 'bin')
    FileUtils.mkdir_p(bin)
    { 'xcodebuild' => 'printf "Xcode 27.0\nBuild version %s\n" "${TEST_XCODE_BUILD:-27A1}"',
      'uname' => 'echo arm64' }.each do |name, command|
      File.write(File.join(bin, name), "#!/bin/bash\n#{command}\n")
      File.chmod(0755, File.join(bin, name))
    end
    ENV['PATH'] = "#{bin}:#{ENV.fetch('PATH')}"
    ENV['TEST_DOWNLOADS'] = File.join(@directory, 'downloads')
    @cache = File.join(@directory, 'global cache')
    @script = File.join(@directory, 'download.sh')
    File.write(@script, <<~'SH')
      set -eu
      directory="$PODS_BUILD_DIR/ReerCodable/1.8.1/$XCODE_VERSION_ACTUAL"
      [[ -x "$directory/ReerCodableMacros" ]] && exit 0
      echo download >> "$TEST_DOWNLOADS"
      [[ "${TEST_TIMEOUT:-0}" == 1 ]] && exit 28
      sleep 0.1
      mkdir -p "$directory"
      printf '#!/bin/sh\nexit 0\n' > "$directory/ReerCodableMacros"
      chmod +x "$directory/ReerCodableMacros"
    SH
  end

  def teardown
    ENV.replace(@environment)
    FileUtils.remove_entry(@directory)
  end

  def prepare
    ReerMacroCache.prepare(@script, '1.8.1', @cache)
  end

  def downloads
    File.readlines(ENV.fetch('TEST_DOWNLOADS')).length
  end

  def test_different_projects_reuse_cache_and_xcode_builds_are_isolated
    first = prepare
    ENV['TEST_TIMEOUT'] = '1'
    assert_equal first, prepare
    assert_equal 1, downloads
    ENV.delete('TEST_TIMEOUT')
    ENV['TEST_XCODE_BUILD'] = '27B2'
    refute_equal first, prepare
    assert_equal 2, downloads
  end

  def test_failed_download_fails_install_and_can_be_retried
    ENV['TEST_TIMEOUT'] = '1'
    spec = Pod::Specification.new do |s|
      s.name = 'ReerCodable'
      s.version = '1.8.1'
      s.script_phase = { :name => 'Prepare ReerCodable macro', :script => File.read(@script) }
    end
    target = Struct.new(:root_spec, :platform).new(spec, Pod::Platform.new(:osx))
    installer = Struct.new(:pod_targets, :sandbox).new([target], Pod::Sandbox.new(File.join(@directory, 'Pods')))
    original = ReerMacroCache.method(:prepare)
    operation = lambda { |script, version| original.call(script, version, @cache) }
    ReerMacroCache.stub(:prepare, operation) do
      error = assert_raises(Pod::Informative) { Pod::Publish::ReerMacroPreparation.prepare(installer) }
      assert_includes error.message, 'retry pod install'
    end
    assert_empty Dir[File.join(@cache, '**/ReerCodableMacros')]
    ENV.delete('TEST_TIMEOUT')
    assert File.executable?(prepare)
  end

  def test_concurrent_projects_download_only_once
    children = 2.times.map do
      fork do
        prepare
        exit! 0
      rescue StandardError
        exit! 1
      end
    end
    children.each { |pid| assert Process.wait2(pid).last.success? }
    assert_equal 1, downloads
  end

  def test_component_versions_do_not_share_an_executable
    first = prepare
    File.write(@script, File.read(@script).sub('1.8.1', '1.8.2'))
    second = ReerMacroCache.prepare(@script, '1.8.2', @cache)
    refute_equal first, second
    assert File.executable?(first)
    assert File.executable?(second)
    assert_equal 2, downloads
  end

  def test_generated_phase_uses_the_standalone_helper_without_bundler_environment
    project = Xcodeproj::Project.new(File.join(@directory, 'Pods.xcodeproj'))
    native = project.new_target(:framework, 'ReerCodable', :osx, '12')
    phase = native.new_shell_script_build_phase('[CP-User] Prepare ReerCodable macro')
    unrelated = native.new_shell_script_build_phase('Other script')
    unrelated.shell_script = 'echo unchanged'
    spec = Pod::Specification.new { |s| s.name = 'ReerCodable'; s.version = '1.8.1' }
    target = Struct.new(:root_spec).new(spec)
    result = Struct.new(:target, :native_target).new(target, native)
    Pod::Publish::ReerMacroPreparation.integrate(result)
    assert_includes phase.shell_script, '-u RUBYOPT'
    assert_includes phase.shell_script, '/ReerCodable/1.8.1/prepare.rb'
    assert_equal '1', phase.always_out_of_date
    assert_equal 'echo unchanged', unrelated.shell_script
  end

  def test_build_copies_shared_cache_to_each_projects_existing_macro_path
    original = ReerMacroCache.method(:prepare)
    ReerMacroCache.stub(:prepare, ->(script, version) { original.call(script, version, @cache) }) do
      %w[ProjectA ProjectB].each do |project|
        ENV['PODS_BUILD_DIR'] = File.join(@directory, project)
        ENV['XCODE_VERSION_ACTUAL'] = '2700'
        ReerMacroCache.install_for_build(@script, '1.8.1')
        assert File.executable?(File.join(ENV['PODS_BUILD_DIR'], 'ReerCodable/1.8.1/2700/ReerCodableMacros'))
      end
    end
    assert_equal 1, downloads
  end
end
