#
# Be sure to run `pod lib lint BTNetwork.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'BTNetwork'
  s.version          = '100'
  s.summary          = '网络模块.'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = <<-DESC
提供网络请求相关服务.
                       DESC

  s.homepage         = 'https://gitlab.v.show/ios_component/btnetwork'
  
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'yuxilong' => '305758560@qq.com' }
  s.source           = { :git => 'https://gitlab.v.show/ios_component/btnetwork.git', :tag => s.version.to_s }

  s.ios.deployment_target = '10.0'

  s.source_files = 'BTNetwork/BTNetwork.h'
  s.default_subspec = 'Core'
 
  s.subspec 'Core' do |ss|
    ss.source_files = 'BTNetwork/Core/*.{h,m}'
    ss.dependency 'BTNetwork/Error'
    ss.dependency 'BTNetwork/Configuration'
    ss.dependency 'BTNetwork/Log'
    ss.dependency 'BTNetwork/ShuMei'
  end

  s.subspec 'Error' do |ss|
    ss.source_files = 'BTNetwork/Error/*.{h,m}'
  end

  s.subspec 'Log' do |ss|
    ss.source_files = 'BTNetwork/Log/*.{h,m}'
  end

  s.subspec 'Configuration' do |ss|
    ss.source_files = 'BTNetwork/Configuration/**/*.{h,m}'
    ss.dependency 'BTNetwork/Plugins'
    ss.dependency 'BTNetwork/ShuMei'
  end

  s.subspec 'Plugins' do |ss|
    ss.source_files = 'BTNetwork/Plugins/*.h'
    ss.dependency 'BTNetwork/Error'
  end

  s.subspec 'ShuMei' do |ss|
    ss.source_files = 'BTNetwork/ShuMeiSDK/**/*.h'
    ss.vendored_libraries = 'BTNetwork/ShuMeiSDK/libSmAntiFraud.a'
  end

  s.dependency 'AFNetworking', '~> 4.0.1'
  s.dependency 'BTBaseKit'
  s.dependency 'BTCrypto_Framework'
  s.dependency 'BTLogger'
  s.pod_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64', 'VALID_ARCHS' => 'arm64 x86_64', 'ENABLE_BITCODE' => 'NO' }
  s.user_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64', 'VALID_ARCHS' => 'arm64 x86_64', 'ENABLE_BITCODE' => 'NO' }
end
