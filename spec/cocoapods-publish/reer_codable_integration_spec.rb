# Created by yuxilong on 2026/10/15.
require File.expand_path('../../spec_helper', __FILE__)
require 'tmpdir'

module Pod
  describe Publish::ReerCodableIntegration do
    before do
      FileUtils.mkdir_p(ROOT + '.tmp')
      @directory = Dir.mktmpdir('macro-spec-', (ROOT + '.tmp').to_s)
      @project = Xcodeproj::Project.new(File.join(@directory, 'Macros.xcodeproj'))
      @definition = Podfile.new { target('App') {} }.target_definitions['App']
      @macro = '-load-plugin-executable "$(PODS_BUILD_DIR)/ReerCodable/1.8.1/$(XCODE_VERSION_ACTUAL)/ReerCodableMacros#ReerCodableMacros"'
      @reer = make_target('ReerCodable')
      @reer.root_spec.pod_target_xcconfig = { 'OTHER_SWIFT_FLAGS' => "$(inherited) #{@macro}" }
      @results = {}
    end

    after do
      FileUtils.remove_entry(@directory) if @directory
    end

    def make_target(name, &block)
      spec = Specification.new do |s|
        s.name = name
        s.version = '1.0.0'
        block.call(s) if block
      end
      PodTarget.new(Sandbox.new(File.join(@directory, 'Pods')), BuildType.dynamic_framework,
                    { 'Debug' => :debug, 'Release' => :release }, [], Platform.new(:osx, '14'),
                    [spec, *spec.recursive_subspecs], [@definition])
    end

    def install_target(target)
      native = @project.new_target(:framework, target.label, :osx, '14')
      tests = target.test_specs.map do |spec|
        @project.new_target(:unit_test_bundle, target.test_target_label(spec), :osx, '14')
      end
      apps = target.app_specs.to_h do |spec|
        [spec, @project.new_target(:application, spec.name.tr('/', '-'), :osx, '14')]
      end
      result = Installer::Xcode::PodsProjectGenerator::TargetInstallationResult.new(target, native, [], tests, {}, [], apps)
      @results[target.label] = result
      result
    end

    def apply
      results = Struct.new(:pod_target_installation_results).new(@results)
      installer = Struct.new(:target_installation_results).new(results)
      Publish::ReerCodableIntegration.apply(installer)
    end

    it 'injects direct and transitive dependencies, preserving flags and avoiding duplicates' do
      direct = make_target('Models')
      direct.dependent_targets = [@reer]
      transitive = make_target('Networking')
      transitive.dependent_targets = [direct]
      native = install_target(direct).native_target
      consumer = install_target(transitive).native_target
      native.build_configurations.first.build_settings['OTHER_SWIFT_FLAGS'] = ['-D', 'CUSTOM']
      consumer.build_configurations.first.build_settings['OTHER_SWIFT_FLAGS'] = '$(inherited) -D APP'
      apply
      apply
      [native, consumer].each do |target|
        target.build_configurations.each do |config|
          config.build_settings['OTHER_SWIFT_FLAGS'].scan(@macro).length.should == 1
          config.build_settings['OTHER_SWIFT_FLAGS'].should.include?('$(inherited)')
        end
      end
      native.build_configurations.first.build_settings['OTHER_SWIFT_FLAGS'].should.include?('-D CUSTOM')
      consumer.build_configurations.first.build_settings['OTHER_SWIFT_FLAGS'].should.include?('-D APP')
    end

    it 'respects configuration-specific dependencies and leaves unrelated targets unchanged' do
      target = make_target('DebugModels')
      target.dependent_targets_by_config = { :debug => [@reer], :release => [] }
      native = install_target(target).native_target
      unrelated = install_target(make_target('Unrelated')).native_target
      apply
      native.build_configurations.find { |c| c.name == 'Debug' }.build_settings['OTHER_SWIFT_FLAGS'].should.include?(@macro)
      native.build_configurations.find { |c| c.name == 'Release' }.build_settings.should.not.key?('OTHER_SWIFT_FLAGS')
      unrelated.build_configurations.each { |c| c.build_settings.should.not.key?('OTHER_SWIFT_FLAGS') }
    end

    it 'injects test-only and app-only dependencies without changing the library target' do
      target = make_target('Support') do |s|
        s.test_spec('Tests') {}
        s.app_spec('Demo') {}
      end
      target.test_dependent_targets_by_spec_name = { 'Support/Tests' => [@reer] }
      target.app_dependent_targets_by_spec_name = { 'Support/Demo' => [@reer] }
      result = install_target(target)
      apply
      result.native_target.build_configurations.each { |c| c.build_settings.should.not.key?('OTHER_SWIFT_FLAGS') }
      result.non_library_specs_by_native_target.each_key do |native|
        native.build_configurations.each { |c| c.build_settings['OTHER_SWIFT_FLAGS'].should.include?(@macro) }
      end
    end

    it 'uses the installed specification version and skips old specifications without macro flags' do
      target = make_target('Models')
      target.dependent_targets = [@reer]
      native = install_target(target).native_target
      @reer.root_spec.pod_target_xcconfig = {}
      apply
      native.build_configurations.each { |c| c.build_settings.should.not.key?('OTHER_SWIFT_FLAGS') }
      @reer.root_spec.pod_target_xcconfig = { 'OTHER_SWIFT_FLAGS' => @macro.sub('1.8.1', '1.9.0') }
      apply
      native.build_configurations.each { |c| c.build_settings['OTHER_SWIFT_FLAGS'].should.include?('/1.9.0/') }
    end

    it 'runs after the user post_install callback without changing its return value' do
      target = make_target('Models')
      target.dependent_targets = [@reer]
      native = install_target(target).native_target
      results = Struct.new(:pod_target_installation_results).new(@results)
      installer = Struct.new(:generated_projects, :target_installation_results).new([@project], results)
      podfile = Podfile.new do
        post_install do |_installer|
          native.build_configurations.each { |c| c.build_settings['OTHER_SWIFT_FLAGS'] = '-D USER_FLAG' }
        end
      end
      podfile.post_install!(installer).should == true
      native.build_configurations.each do |config|
        config.build_settings['OTHER_SWIFT_FLAGS'].should == "$(inherited) -D USER_FLAG #{@macro}"
      end
    end
  end
end
