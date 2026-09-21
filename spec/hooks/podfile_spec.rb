require File.expand_path('../../spec_helper', __FILE__)

module Pod
  describe Podfile do
    it 'normalizes inherited iOS platforms without lowering explicit targets or changing macOS' do
      podfile = Podfile.new do
        platform :ios, '13.0'
        target('Inherited') {}
        target('NewIOS') { platform :ios, '17.0' }
        target('Mac') { platform :osx, '12.0' }
      end

      podfile.normalize_ios_deployment_targets!

      podfile.target_definitions['Inherited'].platform.deployment_target.to_s.should == '15.1'
      podfile.target_definitions['NewIOS'].platform.deployment_target.to_s.should == '17.0'
      podfile.target_definitions['Mac'].platform.should == Platform.new(:osx, '12.0')
    end

    it 'keeps higher iOS deployment targets and other platforms during post_install' do
      project = Xcodeproj::Project.new('/unused/DeploymentTargets.xcodeproj')
      old_ios = project.new_target(:framework, 'OldIOS', :ios, '13.0')
      new_ios = project.new_target(:framework, 'NewIOS', :ios, '17.0')
      mac = project.new_target(:framework, 'Mac', :osx, '12.0')
      installer = Struct.new(:generated_projects).new([project])

      Podfile.new.post_install!(installer)

      old_ios.build_configurations.each do |config|
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'].should == '15.1'
      end
      new_ios.build_configurations.each do |config|
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'].should == '17.0'
      end
      mac.build_configurations.each do |config|
        config.build_settings.should.not.key?('IPHONEOS_DEPLOYMENT_TARGET')
        config.build_settings['MACOSX_DEPLOYMENT_TARGET'].should == '12.0'
      end
    end
  end
end
