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
    end

    after do
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
  end
end
