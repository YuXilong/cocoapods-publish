# Created by yuxilong on 2026/10/29.
require 'minitest/autorun'
require 'tmpdir'
require 'cocoapods'
require_relative '../lib/cocoapods-publish/btlogger_macro_preparation'

class BTLoggerMacroCacheTest < Minitest::Test
  def setup
    root = File.expand_path('../.tmp', __dir__)
    FileUtils.mkdir_p(root)
    @directory = Dir.mktmpdir('btlogger-cache-', root)
    @environment = ENV.to_h
    @source = File.join(@directory, 'source')
    @cache = File.join(@directory, 'cache')
    %w[bin source/scripts source/Sources/BTLoggerMacroPlugin].each { |path|
      FileUtils.mkdir_p(File.join(@directory, path))
    }
    %w[Package.swift Package.resolved Sources/BTLoggerMacroPlugin/LoggerMacro.swift].each { |path|
      File.write(File.join(@source, path), path)
    }
    { 'xcodebuild' => 'printf "Xcode 27.0\nBuild version %s\n" "${TEST_XCODE_BUILD:-27A1}"',
      'uname' => 'echo arm64' }.each do |name, command|
      path = File.join(@directory, 'bin', name)
      File.write(path, "#!/bin/bash\n#{command}\n")
      File.chmod(0755, path)
    end
    ENV['PATH'] = "#{@directory}/bin:#{ENV.fetch('PATH')}"
    ENV['TEST_BUILDS'] = File.join(@directory, 'builds')
    File.write(File.join(@source, 'scripts/build_macro.sh'), <<~'SH')
      set -eu
      echo build >> "$TEST_BUILDS"
      directory="$PODS_BUILD_DIR/BTLoggerMacroPlugin/$CONFIGURATION$EFFECTIVE_PLATFORM_NAME/$XCODE_VERSION_ACTUAL"
      mkdir -p "$directory"
      printf '#!/bin/sh\nexit 0\n' > "$directory/BTLoggerMacroPlugin"
      chmod +x "$directory/BTLoggerMacroPlugin"
      [[ "${TEST_FAIL:-0}" != 1 ]]
    SH
  end

  def teardown
    ENV.replace(@environment)
    FileUtils.remove_entry(@directory)
  end

  def prepare(source = @source)
    BTLoggerMacroCache.prepare(source, @cache)
  end

  def builds
    File.readlines(ENV.fetch('TEST_BUILDS')).size
  end

  def test_cross_project_reuse_and_source_dependency_toolchain_invalidation
    first = prepare
    second_source = File.join(@directory, 'another project')
    FileUtils.cp_r(@source, second_source)
    assert_equal first, prepare(second_source)
    assert_equal 1, builds
    %w[Sources/BTLoggerMacroPlugin/LoggerMacro.swift Package.resolved scripts/build_macro.sh].each do |path|
      File.open(File.join(second_source, path), 'a') { |file| file.puts "\n# changed" }
      refute_equal first, prepare(second_source)
    end
    ENV['TEST_XCODE_BUILD'] = '27B2'
    refute_equal first, prepare
    assert_equal 5, builds
  end

  def test_failed_build_is_not_published_and_retry_succeeds
    ENV['TEST_FAIL'] = '1'
    assert_raises(RuntimeError) { prepare }
    assert_empty Dir[File.join(@cache, 'arm64/BTLogger/*/*/BTLoggerMacroPlugin')]
    ENV.delete('TEST_FAIL')
    assert File.executable?(prepare)
    assert_equal 2, builds
  end

  def test_concurrent_projects_build_once
    children = 2.times.map do
      fork do
        prepare
        exit! 0
      rescue StandardError
        exit! 1
      end
    end
    children.each { |pid| assert Process.wait2(pid).last.success? }
    assert_equal 1, builds
  end

  def test_install_failure_is_fatal_and_legacy_specs_are_skipped
    spec = Pod::Specification.new do |s|
      s.name = 'BTLogger'
      s.version = '136'
      s.script_phase = { :name => 'Build BTLogger macro', :script => '/bin/bash scripts/build_macro.sh' }
    end
    target = Struct.new(:root_spec, :platform).new(spec, Pod::Platform.new(:ios, '15'))
    sandbox = Pod::Sandbox.new(File.join(@directory, 'Pods'))
    sandbox.store_local_path('BTLogger', Pathname(File.join(@source, 'BTLogger.podspec')), false)
    installer = Struct.new(:pod_targets, :sandbox).new([target], sandbox)
    original = BTLoggerMacroCache.method(:prepare)
    BTLoggerMacroCache.stub(:prepare, ->(source) { original.call(source, @cache) }) do
      ENV['TEST_FAIL'] = '1'
      error = assert_raises(Pod::Informative) { Pod::Publish::BTLoggerMacroPreparation.prepare(installer) }
      assert_includes error.message, 'retry pod install'
      ENV.delete('TEST_FAIL')
      Pod::Publish::BTLoggerMacroPreparation.prepare(installer)
    end
    assert File.file?(sandbox.root.join('.cocoapods-publish/BTLogger/prepare.rb'))
    spec.script_phases = []
    BTLoggerMacroCache.stub(:prepare, ->(*) { flunk 'legacy spec must not build' }) do
      Pod::Publish::BTLoggerMacroPreparation.prepare(installer)
    end
  end

  def test_build_phase_uses_cache_for_each_configuration_and_platform
    spec = Pod::Specification.new { |s| s.name = 'BTLogger'; s.version = '136' }
    project = Xcodeproj::Project.new(File.join(@directory, 'Pods.xcodeproj'))
    native = project.new_target(:framework, 'BTLogger', :ios, '15')
    phase = native.new_shell_script_build_phase('[CP-User] Build BTLogger macro')
    result = Struct.new(:target, :native_target).new(Struct.new(:root_spec).new(spec), native)
    Pod::Publish::BTLoggerMacroPreparation.integrate(result)
    assert_includes phase.shell_script, '-u RUBYOPT'
    assert_includes phase.shell_script, '/BTLogger/prepare.rb'
    assert_equal '1', phase.always_out_of_date
    original = BTLoggerMacroCache.method(:prepare)
    BTLoggerMacroCache.stub(:prepare, ->(source) { original.call(source, @cache) }) do
      %w[Debug Release].product(%w[-iphoneos -iphonesimulator]).each do |config, platform|
        ENV.update('PODS_BUILD_DIR' => File.join(@directory, 'Project'), 'CONFIGURATION' => config,
                   'EFFECTIVE_PLATFORM_NAME' => platform, 'XCODE_VERSION_ACTUAL' => '2700')
        BTLoggerMacroCache.install_for_build(@source)
        assert File.executable?(File.join(ENV['PODS_BUILD_DIR'], 'BTLoggerMacroPlugin', config + platform,
                                          '2700/BTLoggerMacroPlugin'))
      end
    end
    assert_equal 1, builds
  end
end
