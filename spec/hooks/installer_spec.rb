require File.expand_path('../../spec_helper', __FILE__)
require 'fileutils'
require 'tmpdir'

module Pod
  describe Installer do
    before do
      @tmp_dir = Dir.mktmpdir
      @installer = Installer.allocate
      @sandbox = Struct.new(:root).new(Pathname(@tmp_dir))
      @installer.instance_variable_set(:@sandbox, @sandbox)
      @previous_source_dependency = Dependency.source_dependency.dup
      @previous_local_dependency_names = Dependency.local_dependency_names.transform_values(&:dup)
      Dependency.source_dependency.clear
      Dependency.local_dependency_names.clear
    end

    after do
      Dependency.source_dependency.clear
      Dependency.source_dependency.merge!(@previous_source_dependency)
      Dependency.local_dependency_names.clear
      Dependency.local_dependency_names.merge!(@previous_local_dependency_names)
      FileUtils.rm_rf(@tmp_dir)
    end

    def yytext_layout_path(pod_name)
      path = File.join(@tmp_dir, pod_name, pod_name, 'Text', 'Component', 'YYTextLayout.m')
      FileUtils.mkdir_p(File.dirname(path))
      path
    end

    def yytext_classes_layout_path
      path = File.join(@tmp_dir, 'YYText', 'YYText', 'Classes', 'Component', 'YYTextLayout.m')
      FileUtils.mkdir_p(File.dirname(path))
      path
    end

    def texture_layout_path
      path = File.join(@tmp_dir, 'Texture', 'Source', 'TextExperiment', 'Component', 'ASTextLayout.mm')
      FileUtils.mkdir_p(File.dirname(path))
      path
    end

    def afnetworking_file_path(file_name)
      path = File.join(@tmp_dir, 'AFNetworking', 'AFNetworking', file_name)
      FileUtils.mkdir_p(File.dirname(path))
      path
    end

    def write_chained_comparisons(file)
      File.write(file, <<~OBJC)
        position = fabs(left - point.y) < fabs(right - point.y) < (right ? prev : next);
        position = fabs(left - point.x) < fabs(right - point.x) < (right ? prev : next);
        position = fabs(left - point.y) < fabs(right - point.y) < (right ? prev : next);
        position = fabs(left - point.x) < fabs(right - point.x) < (right ? prev : next);
      OBJC
    end

    def should_have_patched_chained_comparisons(file)
      content = File.read(file)
      content.should.not.include '< fabs(right - point.y) <'
      content.should.not.include '< fabs(right - point.x) <'
      content.scan('(fabs(left - point.y) < fabs(right - point.y)) ? prev : next;').size.should.equal 2
      content.scan('(fabs(left - point.x) < fabs(right - point.x)) ? prev : next;').size.should.equal 2
    end

    def write_private_netinet6_import(file)
      File.write(file, <<~OBJC)
        #import <netinet/in.h>
        #import <netinet6/in6.h>
        #import <arpa/inet.h>
      OBJC
    end

    def should_have_removed_private_netinet6_import(file)
      content = File.read(file)
      content.should.include '#import <netinet/in.h>'
      content.should.not.include '#import <netinet6/in6.h>'
      content.should.include '#import <arpa/inet.h>'
    end

    def write_lockfile(content)
      lockfile = File.join(@tmp_dir, 'Podfile.lock')
      File.write(lockfile, content)
      Pod::Config.instance.stubs(:lockfile_path).returns(Pathname(lockfile))
    end

    def write_local_pod(name, version, dependencies = {}, subspecs = [])
      pod_dir = File.join(@tmp_dir, name)
      FileUtils.mkdir_p(pod_dir)
      dependency_lines = dependencies.map do |dependency_name, dependency_version|
        "  s.dependency '#{dependency_name}', '#{dependency_version}'"
      end.join("\n")
      source_lines = if subspecs.empty?
                       "  s.source_files = 'Sources/**/*'"
                     else
                       default_subspec = "  s.default_subspec = '#{subspecs.first}'"
                       definitions = subspecs.map do |subspec|
                         <<~SUBSPEC.chomp
                             s.subspec '#{subspec}' do |ss|
                               ss.source_files = 'Sources/#{subspec}/**/*'
                             end
                         SUBSPEC
                       end
                       ([default_subspec] + definitions).join("\n")
                     end
      File.write(File.join(pod_dir, "#{name}.podspec"), <<~PODSPEC)
        Pod::Spec.new do |s|
          s.name = '#{name}'
          s.version = '#{version}'
          s.summary = '#{name} test fixture'
          s.homepage = 'https://example.com/#{name}'
          s.license = { :type => 'MIT' }
          s.author = { 'test' => 'test@example.com' }
          s.source = { :git => 'https://example.com/#{name}.git', :tag => s.version.to_s }
        #{source_lines}
        #{dependency_lines}
        end
      PODSPEC
      pod_dir
    end

    it 'keeps a lockfile containing only module-stable versions' do
      write_lockfile("PODS:\n  - BTLogger (131)\n")
      @installer.instance_variable_set(:@lockfile, :existing)

      @installer.send(:check_swift_version)

      @installer.instance_variable_get(:@lockfile).should == :existing
    end

    it 'keeps a lockfile containing a legacy version for the current Swift compiler' do
      write_lockfile("PODS:\n  - BTLogger (130.swift-#{Installer::SWIFT_VERSION})\n")
      @installer.instance_variable_set(:@lockfile, :existing)

      @installer.send(:check_swift_version)

      @installer.instance_variable_get(:@lockfile).should == :existing
    end

    it 'invalidates a lockfile containing a legacy version for another Swift compiler' do
      write_lockfile("PODS:\n  - BTLogger (130.swift-0.0.0)\n")
      @installer.instance_variable_set(:@lockfile, :existing)

      @installer.send(:check_swift_version)

      @installer.instance_variable_get(:@lockfile).should.be.nil
    end

    it 'patches YYKit chained comparisons for Xcode 26' do
      file = yytext_layout_path('YYKit')
      write_chained_comparisons(file)

      @installer.send(:patch_text_layout_chained_comparison)

      should_have_patched_chained_comparisons(file)
    end

    it 'patches Texture chained comparisons for Xcode 26' do
      file = texture_layout_path
      write_chained_comparisons(file)

      @installer.send(:patch_text_layout_chained_comparison)

      should_have_patched_chained_comparisons(file)
    end

    it 'patches YYText Classes layout path used by CocoaPods' do
      file = yytext_classes_layout_path
      write_chained_comparisons(file)

      @installer.send(:patch_text_layout_chained_comparison)

      should_have_patched_chained_comparisons(file)
    end

    it 'leaves already patched YYTextLayout unchanged' do
      file = yytext_layout_path('YYText')
      patched = <<~OBJC
        position = (fabs(left - point.y) < fabs(right - point.y)) ? prev : next;
        position = (fabs(left - point.x) < fabs(right - point.x)) ? prev : next;
      OBJC
      File.write(file, patched)

      @installer.send(:patch_text_layout_chained_comparison)

      File.read(file).should.equal patched
    end

    it 'removes AFNetworking private netinet6 imports for Xcode 26' do
      files = %w[AFHTTPSessionManager.m AFNetworkReachabilityManager.m].map do |file_name|
        afnetworking_file_path(file_name)
      end
      files.each { |file| write_private_netinet6_import(file) }

      @installer.send(:patch_afnetworking_private_netinet6_header)

      files.each { |file| should_have_removed_private_netinet6_import(file) }
    end

    it 'suggests --precheck after a normal install cannot find a spec' do
      @installer.precheck_dependencies = false
      @installer.stubs(:local_podfile_path).returns(Pathname('/missing/Podfile.local'))
      @installer.stubs(:origin_resolve_dependencies).
        raises(NoSpecFoundError.new('MissingVersion (= 1.0.0)'))

      error = lambda { @installer.resolve_dependencies }.should.raise NoSpecFoundError

      error.message.should.include 'MissingVersion (= 1.0.0)'
      error.message.should.include 'pod install --precheck'
    end

    it 'does not suggest --precheck when precheck is already enabled' do
      @installer.precheck_dependencies = true
      @installer.stubs(:local_podfile_path).returns(Pathname('/missing/Podfile.local'))
      @installer.stubs(:origin_resolve_dependencies).
        raises(NoSpecFoundError.new('MissingVersion (= 1.0.0)'))

      error = lambda { @installer.resolve_dependencies }.should.raise NoSpecFoundError

      error.message.should.not.include 'pod install --precheck'
    end

    it 'passes the precheck setting to the analyzer' do
      analyzer = mock
      @installer.precheck_dependencies = true
      @installer.stubs(:origin_create_analyzer).returns(analyzer)
      analyzer.expects(:precheck_dependencies=).with(true)

      @installer.send(:create_analyzer).should.equal analyzer
    end

    it 'replaces Podfile dependencies with Podfile.local subspecs by root name' do
      podfile_path = File.join(@tmp_dir, 'Podfile')
      local_podfile_path = "#{podfile_path}.local"
      File.write(podfile_path, <<~PODFILE)
        target 'App' do
          pod 'BTStarPetKit', '107'
          pod 'BTGallery/VO', '20'
          pod 'BTPlain/Core'
          pod 'BTLogger', '10'
        end
      PODFILE
      File.write(local_podfile_path, <<~PODFILE)
        pod 'BTStarPetKit/VO', :path => '../BaiTuPods/BTStarPetKit'
        pod 'BTGallery/VO', :path => '../BaiTuPods/BTGallery'
        pod 'BTPlain/VO', :path => '../BaiTuPods/BTPlain'
        pod 'BTLocalOnlyKit', :path => '../BaiTuPods/BTLocalOnlyKit'
      PODFILE
      podfile = Podfile.from_file(Pathname(podfile_path))
      @installer.instance_variable_set(:@podfile, podfile)
      @installer.stubs(:local_podfile_path).returns(Pathname(local_podfile_path))

      @installer.send(:apply_local_podfile)

      dependencies = podfile.target_definitions['App'].instance_variable_get(:@internal_hash)['dependencies']
      dependency_names = dependencies.map do |dependency|
        dependency.is_a?(Hash) ? dependency.keys.first : dependency
      end
      dependency_names.should == %w[BTLogger BTStarPetKit/VO BTGallery/VO BTPlain/VO BTLocalOnlyKit]
    end

    it 'pins the simulator-capable YYImage root and WebP versions while fixing Texture' do
      texture_root = Struct.new(:name).new('Texture')
      yyimage_root = Struct.new(:name).new('YYImage')
      spec = Struct.new(:root, :name, :version)
      target_definition = Object.new
      target_definition.instance_variable_set(:@internal_hash, { 'dependencies' => [] })
      analysis_result = Struct.new(:specs_by_target).new(
        target_definition => [
          spec.new(texture_root, 'Texture/Core', Pod::Version.new('3.1.0')),
          spec.new(yyimage_root, 'YYImage/WebP', Pod::Version.new('1.0.4')),
        ]
      )
      @installer.instance_variable_set(
        :@sandbox,
        Struct.new(:root, :development_pods).new(Pathname(@tmp_dir), {})
      )
      @installer.stubs(:analysis_result).returns(analysis_result)
      @installer.stubs(:texture_user_pinned?).returns(false)
      @installer.stubs(:baitu_specs_available?).returns(true)
      @installer.expects(:origin_resolve_dependencies).once.returns(:resolved)

      @installer.send(:reresolve_for_texture_if_needed, :initial).should == :resolved

      dependencies = target_definition.instance_variable_get(:@internal_hash)['dependencies']
      dependencies.should.include(
        'Texture/Core' => [
          {
            :git => 'https://github.com/BaiTu-iOS/Texture.git',
            :tag => '3.1.0.BAITU',
          },
        ]
      )
      yyimage_source = { :source => 'https://github.com/BaiTu-iOS/baitu-specs.git' }
      dependencies.should.include('YYImage' => ['1.0.4.BAITU', yyimage_source])
      dependencies.should.include('YYImage/WebP' => ['1.0.4.BAITU', yyimage_source])
    end

    it 'resolves the Podfile.local version over a transitive exact version' do
      star_pet_path = write_local_pod('BTStarPetKit', '108', {}, %w[Core VO])
      im_module_path = write_local_pod(
        'BTIMModule',
        '258.b102',
        { 'BTStarPetKit' => '107' },
        %w[Core]
      )
      podfile_path = File.join(@tmp_dir, 'Podfile')
      File.write(podfile_path, <<~PODFILE)
        install! 'cocoapods', :integrate_targets => false
        platform :ios, '13.0'

        target 'App' do
          pod 'BTIMModule', :dev => 1, :path => '#{im_module_path}'
          pod 'BTStarPetKit', '107'
        end
      PODFILE
      File.write("#{podfile_path}.local", <<~PODFILE)
        pod 'BTStarPetKit/VO', :path => '#{star_pet_path}'
      PODFILE
      podfile = Podfile.from_file(Pathname(podfile_path))
      sandbox = Sandbox.new(Pathname(File.join(@tmp_dir, 'Pods')))
      sandbox.prepare
      installer = Installer.new(sandbox, podfile)

      installer.resolve_dependencies

      versions = installer.analysis_result.specifications.each_with_object({}) do |spec, result|
        result[spec.root.name] = spec.version.to_s
      end
      star_pet_specs = installer.analysis_result.specifications.map(&:name).grep(/\ABTStarPetKit/)
      versions['BTIMModule'].should == '258.b102'
      versions['BTStarPetKit'].should == '108'
      star_pet_specs.should.include 'BTStarPetKit/VO'
      star_pet_specs.should.not.include 'BTStarPetKit/Core'
    end
  end
end
