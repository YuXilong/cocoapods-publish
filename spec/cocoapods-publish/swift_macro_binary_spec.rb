# Created by yuxilong on 2026/10/22.
require File.expand_path('../../spec_helper', __FILE__)

module Pod
  describe 'BTLogger macro binary specification' do
    before do
      @phase = {
        'name' => 'Build BTLogger macro',
        'script' => '/bin/bash "${PODS_TARGET_SRCROOT}/scripts/build_macro.sh"',
        'execution_position' => 'before_compile'
      }
      @flags = '-load-plugin-executable "${PODS_BUILD_DIR}/BTLoggerMacroPlugin#BTLoggerMacroPlugin"'
      @files = %w[Package.swift Package.resolved scripts/build_macro.sh Sources/BTLoggerMacroPlugin/LoggerMacro.swift]
      @manifest = {
        'component' => { 'name' => 'BTLogger', 'version' => '135' },
        'artifact' => { 'path' => 'BTLogger.xcframework', 'linkage' => 'static' },
        'specification' => {
          'name' => 'BTLogger', 'version' => '135', 'platforms' => { 'ios' => '15.0' },
          'script_phases' => [@phase], 'preserve_paths' => ['Unused/*'],
          'pod_target_xcconfig' => { 'OTHER_SWIFT_FLAGS' => "-D SOURCE_ONLY #{@flags}" }
        },
        'selected_specs' => ['BTLogger'], 'module_name' => 'BTLogger',
        'vendored_frameworks' => [], 'resources' => [],
        'swift_macro_support' => { 'module' => 'BTLoggerMacroPlugin', 'files' => @files }
      }
    end

    it 'preserves the host build phase and injects only the macro flag for app and pod consumers' do
      result = BinarySpecification.new(@manifest).attributes
      result['preserve_paths'].should == @files
      result['script_phases'].first[:script].should == @phase['script']
      %w[pod_target_xcconfig user_target_xcconfig].each { |key| result[key]['OTHER_SWIFT_FLAGS'].should == @flags }
      result.key?('source_files').should == false
      result.key?('resources').should == false
    end

    it 'rejects missing metadata, missing files, traversal and unrelated scripts' do
      @manifest.delete('swift_macro_support')
      should.raise(Informative) { BinarySpecification.new(@manifest).attributes }
      @manifest['swift_macro_support'] = { 'module' => 'BTLoggerMacroPlugin', 'files' => [] }
      should.raise(Informative) { BinarySpecification.new(@manifest).attributes }
      @manifest['swift_macro_support']['files'] = @files + ['../outside']
      should.raise(Informative) { BinarySpecification.new(@manifest).attributes }
      @manifest['swift_macro_support']['files'] = @files
      @phase['script'] = 'echo unsupported'
      should.raise(Informative) { BinarySpecification.new(@manifest).attributes }
    end

    it 'uses manifest generation even when the source spec has a legacy CoreFramework section' do
      command = Command::Publish.new(CLAide::ARGV.new(['Repo', 'BTLogger.podspec']))
      command.instance_variable_set(:@push_podspec_file, 'BTLogger.podspec')
      command.stubs(:validate_artifact_manifest!)
      File.stubs(:open).with('BTLogger.podspec').returns(StringIO.new("s.subspec 'CoreFramework' do |ss|\nend"))
      command.expects(:write_binary_specification).with('repository/files/135', @manifest)
      command.send(:modify_zip_path, 'repository/files/135', @manifest)
    end
  end
end
