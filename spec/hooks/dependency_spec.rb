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
      Config.instance.repos_dir = Pathname(@tmp_dir)
      Dependency.source_dependency.clear
    end

    after do
      Config.instance.repos_dir = @previous_repos_dir
      Dependency.source_dependency.clear
      Dependency.source_dependency.merge!(@previous_source_dependency)
      FileUtils.rm_rf(@tmp_dir)
    end

    def write_framework_podspec(fw, version)
      folder_version = "#{version}.swift-#{Dependency::SWIFT_VERSION}"
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
      write_framework_podspec(fw, '1.9.0')
      write_framework_podspec(fw, '1.10.0')

      @dependency.local_framework_version(fw).should.equal "1.10.0.swift-#{Dependency::SWIFT_VERSION}"
    end

    it 'does not sort beta 99 before release 100' do
      fw = 'BTMajorVersionSort'
      write_framework_podspec(fw, '99.b1')
      write_framework_podspec(fw, '100')

      @dependency.local_framework_version(fw).should.equal "100.swift-#{Dependency::SWIFT_VERSION}"
    end

    it 'sorts beta before release for the same base version' do
      fw = 'BTBetaPrioritySort'
      write_framework_podspec(fw, '100')
      write_framework_podspec(fw, '100.b1')

      @dependency.local_framework_version(fw).should.equal "100.b1.swift-#{Dependency::SWIFT_VERSION}"
    end

    it 'sorts beta versions by numeric beta number' do
      fw = 'BTBetaNumberSort'
      write_framework_podspec(fw, '100.b2')
      write_framework_podspec(fw, '100.b10')

      @dependency.local_framework_version(fw).should.equal "100.b10.swift-#{Dependency::SWIFT_VERSION}"
    end

    it 'returns an empty requirement when no local framework version exists' do
      @dependency.local_framework_version('BTMissing').should.equal []
    end
  end
end
