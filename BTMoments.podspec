use_framework = ENV['USE_FRAMEWORK']
dev_framework = ENV['USE_DEV_FRAMEWORK_BTMoments']
use_framework = dev_framework ? false : use_framework

# 支持的混淆模式, 例如：SUPPORT_MIXUP = ['XXX', 'YYY']
SUPPORT_MIXUP = [
    'PLA' => 'PLAFlashbacksTool',
    'VO' => 'VOSnapshotsModule',
#    'MNL' => 'MNLHighlightsComponent',
#    'MTI' => 'MTIScenesGlimpses',
#    'MIU' => 'MIUSocialPanel'
]

# Beta版本 默认不包含BT 例如：BETA_SUPPORT_MIXUP = ['VO']
BETA_SUPPORT_MIXUP = [
    'PLA' => 'PLAFlashbacksTool',
#    'VO' => 'VOSnapshotsModule',
#    'MNL' => 'MNLHighlightsComponent',
#    'MTI' => 'MTIScenesGlimpses',
#    'MIU' => 'MIUSocialPanel'
]

# 函数混淆支持
#SUPPORT_FUCNTION_MIXUP = ['PLA', 'VO', 'MNL']
SUPPORT_FUCNTION_MIXUP = ['PLA', 'VO']

# subspec支持
#BUILD_SUBSPECS = ['PLA', 'VO', 'MNL']
BUILD_SUBSPECS = ['PLA', 'VO']

Pod::Spec.new do |s|
  s.name             = 'BTMoments'
  s.version          = '141.b100'
  s.summary          = '动态、小视频模块.'

  s.description      = <<-DESC
  动态、小视频模块.
                       DESC

  git_source = use_framework ? "https://gitlab.v.show/ios_framework/#{s.name.to_s}.git" : "https://gitlab.v.show/ios_component/#{s.name.to_s}.git"

  s.homepage         = git_source
  s.author           = { 'yuxilong' => '305758560@qq.com' }

  zip_file_path = "repository/files/#{s.version}"
  if use_framework
    s.default_subspec = 'CoreFramework'
    s.source = {
      :http => "https://gitlab.v.show/api/v4/projects/291/#{zip_file_path}%2F#{s.name.to_s}-#{s.version.to_s}.zip/raw?ref=main",
      :http_VO => "https://gitlab.v.show/api/v4/projects/291/#{zip_file_path}%2FVOSNAPSHOTSMODULE-#{s.version.to_s}.zip/raw?ref=main",
      :http_PLA => "https://gitlab.v.show/api/v4/projects/291/#{zip_file_path}%2FPLAFLASHBACKSTOOL-#{s.version.to_s}.zip/raw?ref=main",
      :http_MIU => "https://gitlab.v.show/api/v4/projects/291/#{zip_file_path}%2FMIUSOCIALPANEL-#{s.version.to_s}.zip/raw?ref=main",
      :http_MTI => "https://gitlab.v.show/api/v4/projects/291/#{zip_file_path}%2FMTISCENESGLIMPSES-#{s.version.to_s}.zip/raw?ref=main",
      :http_MNL => "https://gitlab.v.show/api/v4/projects/291/#{zip_file_path}%2FMNLHIGHLIGHTSCOMPONENT-#{s.version.to_s}.zip/raw?ref=main",
      :http_ZSL => "https://gitlab.v.show/api/v4/projects/291/#{zip_file_path}%2FZSLMoments-#{s.version.to_s}.zip/raw?ref=main",
      :http_PPL => "https://gitlab.v.show/api/v4/projects/291/#{zip_file_path}%2FPPLMoments-#{s.version.to_s}.zip/raw?ref=main",
      :type => "zip",
      :headers => ["Authorization: Bearer #{ENV['GIT_LAB_TOKEN']}"]
    }
  else
    s.default_subspec   = 'Core'
    s.license           = { :type => 'MIT', :file => 'LICENSE' }
    s.source            = { :git => git_source, :tag => s.version.to_s }
  end

  s.ios.deployment_target = '12.0'
  s.static_framework      = true
  s.pod_target_xcconfig   = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64', 'VALID_ARCHS' => 'arm64' }
  s.user_target_xcconfig  = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64', 'VALID_ARCHS' => 'arm64' }

  s.subspec 'CoreFramework' do |ss|
    ss.vendored_frameworks = 'BTMoments.framework'
    ss.resource = "BTMoments.bundle"
  end

  s.subspec 'Core' do |ss|
    ss.dependency 'BTMoments/Base'
    ss.dependency 'BTMoments/V1'
#    ss.dependency 'BTMoments/V2'
  end

  s.subspec 'Base' do |ss|
      ss.source_files = 'BTMoments/Classes/Base/**/*.{h,m}'
      ss.dependency 'BTMoments/Resource'
      ss.prefix_header_contents = [
        '#import "BTMomentsDefines.h"',
        "static NSString *const kMoments_Bundle = @\"#{s.name.to_s}\";"
      ]
  end

  s.subspec 'PLA' do |ss|
    ss.dependency 'BTMoments/Base'
    ss.dependency 'BTMoments/V1'
  end

  s.subspec 'VO' do |ss|
    ss.dependency 'BTMoments/Base'
    ss.dependency 'BTMoments/V2'
  end

  s.subspec 'MNL' do |ss|
    ss.dependency 'BTMoments/Base'
    ss.dependency 'BTMoments/V3'
  end

  s.subspec 'MTI' do |ss|
    ss.dependency 'BTMoments/Base'
    ss.dependency 'BTMoments/V6'
  end

  s.subspec 'MIU' do |ss|
    ss.dependency 'BTMoments/Base'
    ss.dependency 'BTMoments/V7'
  end

  s.subspec 'Sea' do |ss|
      ss.source_files = 'BTMoments/Classes/Sea/**/*'
  end

  s.subspec 'NewDynamic' do |ss|
      ss.source_files = 'BTMoments/Classes/NewDynamic/**/*'
  end

  s.subspec 'V1' do |ss|
      ss.source_files = 'BTMoments/Classes/V1/**/*'
      ss.dependency 'BTMoments/Sea'
      ss.dependency 'BTMoments/NewDynamic'
  end

  s.subspec 'V2' do |ss|
      ss.source_files = 'BTMoments/Classes/V2/**/*'
      ss.dependency 'BTMoments/Sea'
      ss.dependency 'BTMoments/NewDynamic'
  end

  s.subspec 'V3' do |ss|
      ss.source_files = 'BTMoments/Classes/V3/**/*'
  end

  s.subspec 'V6' do |ss|
      ss.source_files = 'BTMoments/Classes/V6/**/*'
  end

  s.subspec 'V7' do |ss|
      ss.source_files = 'BTMoments/Classes/V7/**/*'
  end

  s.subspec 'Resource' do |ss|
    ss.resource_bundle = { s.name.to_s => ['BTMoments/Assets/*.xcassets','BTMoments/Assets/Images/**/*.png']}
  end

  s.dependency 'Masonry'
  s.dependency 'DZNEmptyDataSet'
  s.dependency 'pop'
  s.dependency 'YYWebImage'
  s.dependency 'SDWebImage'
#  s.dependency 'JPVideoPlayer', "3.1.3.BAITU"
  s.dependency 'TMNavigationController'
  s.dependency 'SDCycleScrollView'
  s.dependency 'YYText'
  s.dependency 'ReactiveObjC'
#  s.dependency 'KTVHTTPCache'
  s.dependency 'JXPagingView/Pager','2.1.3'

  s.dependency 'BTBaseKit'
  s.dependency 'BTNetwork'
  s.dependency 'BTAssets'
  s.dependency 'BTRTLAdapter'
  s.dependency 'BTGlobalConfig'
  s.dependency 'BTPagerView'
  s.dependency 'BTLocalization'
  s.dependency 'BTRouter'
  s.dependency 'BTToast'
#  s.dependency 'BTImagePickerModule'
  s.dependency 'BTUserInfo'
  s.dependency 'BTComponentsKit'
#  s.dependency 'BTWKWeb'
#  s.dependency 'BTUserStateManager'
  s.dependency 'AliPlayerSDK_iOS','7.6.0'


end
