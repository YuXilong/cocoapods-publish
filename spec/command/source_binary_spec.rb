# Created by yuxilong on 2026/10/20.
require File.expand_path('../../spec_helper', __FILE__)
require 'cocoapods-publish/binary_specification'
require 'tmpdir'

describe Pod::BinarySpecification do
  it 'updates source spec versions independently of alignment and quotes' do
    command = Pod::Command::Publish.allocate
    ["s.version = '1'", 's.version="1"', "  s.version          = '1'"].each do |declaration|
      text = declaration.dup
      command.send(:replace_spec_version!, text, '1', '2.b1')
      text.should == declaration.sub('1', '2.b1')
    end
  end

  before do
    @spec = Pod::Spec.new do |s|
      s.name = 'Room'
      s.version = '1'
      s.summary = 'Room'
      s.homepage = 'https://example.com/Room'
      s.author = 'Example'
      s.license = { :type => 'MIT', :file => 'LICENSE' }
      s.source = { :git => 'https://example.com/Room.git' }
      s.ios.deployment_target = '15.0'
      s.default_subspecs = 'Core'
      s.dependency 'RootDep', '~> 2.0'
      s.subspec 'Core' do |ss|
        ss.source_files = 'Classes/*.m'
        ss.dependency 'Room/Resource'
        ss.dependency 'CoreDep', '3'
        ss.frameworks = 'UIKit'
      end
      s.subspec 'Resource' do |ss|
        ss.resource_bundles = { 'Room' => ['Assets/*'] }
      end
      s.subspec('Unused') { |ss| ss.dependency 'UnusedDep' }
      s.test_spec('Tests') { |ss| ss.source_files = 'Tests/*.m' }
    end
    @manifest = {
      'component' => { 'name' => 'Room', 'version' => '2.VO-CF' },
      'artifact' => { 'path' => 'Room.xcframework', 'linkage' => 'static' },
      'specification' => @spec.to_hash,
      'selected_specs' => %w[Room Room/Core Room/Resource],
      'module_name' => 'Room',
      'vendored_frameworks' => ['Vendor.xcframework'],
      'resources' => [{ 'path' => 'Room.bundle', 'type' => 'bundle' }],
    }
  end

  it 'generates binary declarations from the selected build and preserves dependency constraints' do
    result = Pod::BinarySpecification.new(@manifest).attributes
    result['version'].should == '2.VO-CF'
    result['vendored_frameworks'].should == %w[Room.xcframework Vendor.xcframework]
    result['resources'].should == ['Room.bundle']
    result['dependencies'].should == { 'RootDep' => ['~> 2.0'], 'CoreDep' => ['= 3'] }
    result['frameworks'].should == ['UIKit']
    %w[source_files subspecs test_specs default_subspecs resource_bundles].each do |key|
      result.key?(key).should == false
    end
    result['license'].should == { 'type' => 'MIT' }
    Pod::Spec.from_hash(result).test_specs.should.be.empty
  end

  it 'keeps runtime authentication out of generated text and resolves it when loaded' do
    generator = Pod::BinarySpecification.new(@manifest)
    previous = ENV['GIT_LAB_TOKEN']
    ENV['GIT_LAB_TOKEN'] = 'test-secret-never-serialize'
    rendered = generator.render('https://example.com/Room.zip')
    rendered.should.not.include('test-secret-never-serialize')
    Dir.mktmpdir('binary-spec-', File.dirname(__FILE__)) do |directory|
      path = File.join(directory, 'Room.podspec')
      File.write(path, rendered)
      loaded = Pod::Spec.from_file(path)
      loaded.source[:headers].should == ['Authorization: Bearer test-secret-never-serialize']
      loaded.source[:http].should == 'https://example.com/Room.zip'
    end
  ensure
    ENV['GIT_LAB_TOKEN'] = previous
  end

  it 'rejects identity mismatches and missing build metadata' do
    @manifest['component']['name'] = 'OtherRoom'
    should.raise(Pod::Informative) { Pod::BinarySpecification.new(@manifest).attributes }
    @manifest.delete('specification')
    should.raise(Pod::Informative) { Pod::BinarySpecification.new(@manifest).attributes }
  end

  it 'recovers missing or historical binary aliases from the actual build metadata' do
    %w[CoreFramework DRL_Framework].each do |subspec|
      Dir.mktmpdir('legacy-alias-', File.dirname(__FILE__)) do |directory|
        path = File.join(directory, 'Room.podspec')
        File.write(path, <<~SPEC)
          Pod::Spec.new do |s|
            s.name = 'Room'
            s.version = '1'
            s.subspec '#{subspec}' do |ss|
              ss.vendored_frameworks = 'HISTORICALROOM.framework'
            end
          end
        SPEC
        command = Pod::Command::Publish.allocate
        command.instance_variable_set(:@push_podspec_file, path)
        command.instance_variable_set(:@spec, @spec)
        command.instance_variable_set(:@new_spec_name, 'Room')
        command.instance_variable_set(:@new_version, '2.VO-CF')
        command.stubs(:validate_artifact_manifest!)
        command.stubs(:get_project_id).returns(1)
        command.send(:modify_zip_path, 'repository/files/audit', @manifest)
        generated = Pod::Spec.from_file(path).to_hash
        generated['vendored_frameworks'].should == %w[Room.xcframework Vendor.xcframework]
        generated['resources'].should == ['Room.bundle']
        generated['dependencies'].should == { 'RootDep' => ['~> 2.0'], 'CoreDep' => ['= 3'] }
      end
    end
  end

  it 'merges plural build settings across subspecs like CocoaPods' do
    @manifest['specification']['subspecs'][0]['pod_target_xcconfig'] = {
      'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) COCOA_ONLY=1 GPB_IMPORT=1'
    }
    @manifest['specification']['subspecs'][1]['pod_target_xcconfig'] = {
      'GCC_PREPROCESSOR_DEFINITIONS' => 'GPB_IMPORT=1'
    }
    flags = Pod::BinarySpecification.new(@manifest).attributes.fetch('pod_target_xcconfig')
    flags['GCC_PREPROCESSOR_DEFINITIONS'].should.include('COCOA_ONLY=1')
    flags['GCC_PREPROCESSOR_DEFINITIONS'].should.include('GPB_IMPORT=1')
    @manifest['specification']['subspecs'][0]['pod_target_xcconfig'] = { 'GCC_PREPROCESSOR_DEFINITIONS' => 'ROOT=1' }
    @manifest['specification']['subspecs'][1]['pod_target_xcconfig'] = { 'GCC_PREPROCESSOR_DEFINITIONS' => 'CHILD=1' }
    @manifest['specification']['subspecs'] << {
      'name' => 'Repeated', 'pod_target_xcconfig' => { 'GCC_PREPROCESSOR_DEFINITIONS' => 'ROOT=1' }
    }
    @manifest['selected_specs'] << 'Room/Repeated'
    flags = Pod::BinarySpecification.new(@manifest).attributes.fetch('pod_target_xcconfig')
    flags['GCC_PREPROCESSOR_DEFINITIONS'].should == 'ROOT=1 CHILD=1'
  end

  it 'discards source Swift flags before checking conflicts but still rejects scalar conflicts' do
    core, resource = @manifest['specification']['subspecs']
    core['pod_target_xcconfig'] = { 'OTHER_SWIFT_FLAGS' => '$(inherited) -DV1' }
    resource['pod_target_xcconfig'] = { 'OTHER_SWIFT_FLAGS' => '$(inherited) -DV2' }
    Pod::BinarySpecification.new(@manifest).attributes.key?('pod_target_xcconfig').should == false
    core['pod_target_xcconfig'] = { 'DEFINES_MODULE' => 'YES' }
    resource['pod_target_xcconfig'] = { 'DEFINES_MODULE' => 'NO' }
    should.raise(Pod::Informative) { Pod::BinarySpecification.new(@manifest).attributes }
  end

  it 'rejects traversal paths, unbuilt internal dependencies, and script phases' do
    @manifest['resources'][0]['path'] = '../Room.bundle'
    should.raise(Pod::Informative) { Pod::BinarySpecification.new(@manifest).attributes }
    @manifest['resources'] = []
    @manifest['selected_specs'].delete('Room/Resource')
    should.raise(Pod::Informative) { Pod::BinarySpecification.new(@manifest).attributes }
    @manifest['selected_specs'] << 'Room/Resource'
    @manifest['specification']['script_phases'] = [{ 'name' => 'Custom', 'script' => 'echo custom' }]
    should.raise(Pod::Informative) { Pod::BinarySpecification.new(@manifest).attributes }
    @manifest['specification'].delete('script_phases')
    @manifest['specification']['ios'] = { 'script_phases' => [{ 'name' => 'iOS', 'script' => 'echo ios' }] }
    should.raise(Pod::Informative) { Pod::BinarySpecification.new(@manifest).attributes }
  end
end
