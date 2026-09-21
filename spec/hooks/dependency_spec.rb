require File.expand_path('../../spec_helper', __FILE__)
require 'fileutils'
require 'tmpdir'

module Pod
  describe Dependency do
    before do
      @tmp_dir = Dir.mktmpdir
      @dependency = Dependency.allocate
      @previous_repos_dir = Config.instance.repos_dir
      @previous_source_dependency = Dependency.source_dependency.dup
      @previous_local_dependency_names = Dependency.local_dependency_names.transform_values(&:dup)
      Config.instance.repos_dir = Pathname(@tmp_dir)
      Dependency.source_dependency.clear
      Dependency.local_dependency_names.clear
    end

    after do
      Config.instance.repos_dir = @previous_repos_dir
      Dependency.source_dependency.clear
      Dependency.source_dependency.merge!(@previous_source_dependency)
      Dependency.local_dependency_names.clear
      Dependency.local_dependency_names.merge!(@previous_local_dependency_names)
      FileUtils.rm_rf(@tmp_dir)
    end

    def write_framework_podspec(fw, version, swift_version: nil)
      folder_version = swift_version.nil? ? version : "#{version}.swift-#{swift_version}"
      podspec_dir = File.join(@tmp_dir, 'BaiTuFrameworkPods', fw, folder_version)
      FileUtils.mkdir_p(podspec_dir)
      podspec_path = File.join(podspec_dir, "#{fw}.podspec")

      File.open(podspec_path, 'w') do |file|
        file.write <<~PODSPEC
          Pod::Spec.new do |s|
            s.name = '#{fw}'
            s.version = '#{folder_version}'
            s.summary = 'Dependency test fixture'
            s.homepage = 'https://example.com/#{fw}'
            s.license = { :type => 'MIT' }
            s.author = { 'test' => 'test@example.com' }
            s.source = { :git => 'https://example.com/#{fw}.git', :tag => s.version.to_s }
            s.source_files = 'Sources/**/*'
          end
        PODSPEC
      end
    end

    it 'sorts release versions by numeric version segments' do
      fw = 'BTVersionSort'
      write_framework_podspec(fw, '1.9.0', swift_version: Dependency::SWIFT_VERSION)
      write_framework_podspec(fw, '1.10.0', swift_version: Dependency::SWIFT_VERSION)

      @dependency.local_framework_version(fw).should.equal "1.10.0.swift-#{Dependency::SWIFT_VERSION}"
    end

    it 'does not sort beta 99 before release 100' do
      fw = 'BTMajorVersionSort'
      write_framework_podspec(fw, '99.b1', swift_version: Dependency::SWIFT_VERSION)
      write_framework_podspec(fw, '100', swift_version: Dependency::SWIFT_VERSION)

      @dependency.local_framework_version(fw).should.equal "100.swift-#{Dependency::SWIFT_VERSION}"
    end

    it 'sorts beta before release for the same base version' do
      fw = 'BTBetaPrioritySort'
      write_framework_podspec(fw, '100', swift_version: Dependency::SWIFT_VERSION)
      write_framework_podspec(fw, '100.b1', swift_version: Dependency::SWIFT_VERSION)

      @dependency.local_framework_version(fw).should.equal "100.b1.swift-#{Dependency::SWIFT_VERSION}"
    end

    it 'sorts beta versions by numeric beta number' do
      fw = 'BTBetaNumberSort'
      write_framework_podspec(fw, '100.b2', swift_version: Dependency::SWIFT_VERSION)
      write_framework_podspec(fw, '100.b10', swift_version: Dependency::SWIFT_VERSION)

      @dependency.local_framework_version(fw).should.equal "100.b10.swift-#{Dependency::SWIFT_VERSION}"
    end

    it 'returns an empty requirement when no local framework version exists' do
      @dependency.local_framework_version('BTMissing').should.equal []
    end

    it 'selects the newest compatible version across stable and legacy artifacts' do
      fw = 'BTModuleStableNewest'
      write_framework_podspec(fw, '100', swift_version: Dependency::SWIFT_VERSION)
      write_framework_podspec(fw, '101')

      @dependency.local_framework_version(fw).should.equal '101'
    end

    it 'prefers a stable artifact when the base version is also published as legacy' do
      fw = 'BTModuleStablePreferred'
      write_framework_podspec(fw, '100', swift_version: Dependency::SWIFT_VERSION)
      write_framework_podspec(fw, '100')

      @dependency.local_framework_version(fw).should.equal '100'
    end

    it 'ignores legacy artifacts built by a different Swift compiler' do
      fw = 'BTLegacyCompiler'
      write_framework_podspec(fw, '100', swift_version: Dependency::SWIFT_VERSION)
      write_framework_podspec(fw, '101', swift_version: '0.0.0')

      @dependency.local_framework_version(fw).should.equal "100.swift-#{Dependency::SWIFT_VERSION}"
    end

    it 'keeps an explicitly requested stable version unchanged' do
      fw = 'BTStableRequirement'
      write_framework_podspec(fw, '100')

      @dependency.genrate_requirements(fw, ['100']).should.equal '100'
    end

    it 'does not pin an unversioned dependency to a stable release because legacy artifacts exist' do
      fw = 'BTDeploymentTargetRegression'
      write_framework_podspec(fw, '130', swift_version: Dependency::SWIFT_VERSION)
      write_framework_podspec(fw, '133')
      write_framework_podspec(fw, '134')

      Dependency.new(fw, []).requirement.should == Requirement.default
      Dependency.modified_frameworks.should.not.key?(fw)
      Dependency.new(fw, '130').requirement.as_list.should == ["= 130.swift-#{Dependency::SWIFT_VERSION}"]
    end

    it 'preserves automatic legacy and beta selection when the selected artifact is not a stable release' do
      legacy = 'BTLegacyAutoSelection'
      write_framework_podspec(legacy, '130', swift_version: Dependency::SWIFT_VERSION)
      Dependency.new(legacy, []).requirement.as_list.should == ["= 130.swift-#{Dependency::SWIFT_VERSION}"]

      beta = 'BTBetaAutoSelection'
      write_framework_podspec(beta, '130', swift_version: Dependency::SWIFT_VERSION)
      write_framework_podspec(beta, '131.b1')
      Dependency.new(beta, []).requirement.as_list.should == ['= 131.b1']
    end

    it 'maps an explicitly requested legacy compiler version to the stable artifact' do
      fw = 'BTExplicitLegacyRequirement'
      write_framework_podspec(fw, '100')

      dependency = Dependency.new(fw, '100.swift-0.0.0')

      dependency.requirement.as_list.should == ['= 100']
    end

    it 'falls back to the current compiler legacy artifact when no stable version exists' do
      fw = 'BTLegacyRequirement'
      write_framework_podspec(fw, '100', swift_version: Dependency::SWIFT_VERSION)

      @dependency.genrate_requirements(fw, ['100']).should.equal "100.swift-#{Dependency::SWIFT_VERSION}"
    end

    it 'resolves a version range to a stable artifact when one is available' do
      fw = 'BTStableRangeRequirement'
      write_framework_podspec(fw, '100', swift_version: Dependency::SWIFT_VERSION)
      write_framework_podspec(fw, '100')

      @dependency.genrate_requirements(fw, ['~> 100']).should.equal '100'
    end

    it 'resolves a version range to a compatible legacy artifact as a fallback' do
      fw = 'BTLegacyRangeRequirement'
      write_framework_podspec(fw, '100', swift_version: Dependency::SWIFT_VERSION)

      @dependency.genrate_requirements(fw, ['~> 100']).should.equal "100.swift-#{Dependency::SWIFT_VERSION}"
    end

    it 'maps the legacy YYImage root and WebP exact versions to the simulator-capable release' do
      root = Dependency.new('YYImage', '1.0.4')
      webp = Dependency.new('YYImage/WebP', '1.0.4')

      root.requirement.as_list.should == ['= 1.0.4.BAITU']
      webp.requirement.as_list.should == ['= 1.0.4.BAITU']
      root.podspec_repo.should == Installer::YYIMAGE_FORK_SOURCE[:source]
      webp.podspec_repo.should == Installer::YYIMAGE_FORK_SOURCE[:source]
    end

    it 'pins an unversioned transitive YYImage dependency before the first resolution' do
      dependency = Dependency.new('YYImage')

      dependency.requirement.as_list.should == ['= 1.0.4.BAITU']
      dependency.podspec_repo.should == Installer::YYIMAGE_FORK_SOURCE[:source]
    end

    it 'maps YYImage requirements loaded from a podspec consumer' do
      dependency = Dependency.new('YYImage/WebP', ['1.0.4'])

      dependency.requirement.as_list.should == ['= 1.0.4.BAITU']
      dependency.podspec_repo.should == Installer::YYIMAGE_FORK_SOURCE[:source]
    end

    it 'routes the simulator-capable YYImage version to the fork Specs repository' do
      dependency = Dependency.new('YYImage/WebP', '1.0.4.BAITU')

      dependency.requirement.as_list.should == ['= 1.0.4.BAITU']
      dependency.podspec_repo.should == Installer::YYIMAGE_FORK_SOURCE[:source]
    end

    it 'keeps unrelated YYImage versions unchanged' do
      dependency = Dependency.new('YYImage/WebP', '1.0.3')

      dependency.requirement.as_list.should == ['= 1.0.3']
      dependency.podspec_repo.should.be.nil
    end

    it 'lets a local path pod override transitive exact version requirements' do
      local_path = File.join(@tmp_dir, 'BTStarPetKit')
      local_dependency = Dependency.new('BTStarPetKit', path: local_path)
      Dependency.register_local_path(local_dependency.name, local_path)

      transitive_dependency = Dependency.new('BTStarPetKit', '107')
      transitive_subspec_dependency = Dependency.new('BTStarPetKit/Core', '107')
      unrelated_dependency = Dependency.new('BTIMModule', '258.b102')
      yyimage_path = File.join(@tmp_dir, 'YYImage')
      Dependency.new('YYImage', path: yyimage_path)
      Dependency.register_local_path('YYImage', yyimage_path)
      special_case_dependency = Dependency.new('YYImage', '1.0.4')

      local_dependency.external_source.should == { path: local_path }
      transitive_dependency.requirement.should == Requirement.default
      transitive_subspec_dependency.requirement.should == Requirement.default
      unrelated_dependency.requirement.as_list.should == ['= 258.b102']
      special_case_dependency.requirement.should == Requirement.default
      special_case_dependency.podspec_repo.should.be.nil
    end

    it 'records the local subspec without changing dependency identity during initialization' do
      local_dependency = Dependency.new(
        'BTStarPetKit/VO',
        path: File.join(@tmp_dir, 'BTStarPetKit')
      )
      Dependency.register_local_path(
        local_dependency.name,
        local_dependency.external_source[:path]
      )

      transitive_root = Dependency.new('BTStarPetKit', '107')
      transitive_core = Dependency.new('BTStarPetKit/Core')

      local_dependency.name.should == 'BTStarPetKit/VO'
      Dependency.local_dependency_name('BTStarPetKit').should == 'BTStarPetKit/VO'
      transitive_root.name.should == 'BTStarPetKit'
      transitive_root.requirement.should == Requirement.default
      transitive_core.name.should == 'BTStarPetKit/Core'
      transitive_core.requirement.should == Requirement.default
    end
  end
end
