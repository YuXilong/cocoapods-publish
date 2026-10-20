# Created by yuxilong on 2026/10/20.
# 源码规格草案；混淆配置保留，二进制规格由插件生成。
# 支持的混淆模式
SUPPORT_MIXUP = [
  'PLA' => 'PLAHTLS',
  'VO' => 'VOOStream',
  # 'MIU' => 'MIUViewerSphere',
]

# Beta版本 默认不包含BT
BETA_SUPPORT_MIXUP = [
  'PLA' => 'PLAHTLS',
  'VO' => 'VOOStream',
#    'MIU' => 'MIUViewerSphere',
]

# SUPPORT_PROPERTY_MIXUP = ['VO', 'PLA', 'MIU']
SUPPORT_FUCNTION_MIXUP = ['VO', 'PLA', 'MIU']

# 最低Swift组件版本依赖
MIN_SWIFT_DEPENDENCY_VERSION = []

Pod::Spec.new do |s|
  s.name             = 'BTLiveRoom'
  s.version          = '268.b1'
  s.summary          = '直播间模块.'

  s.description      = '直播间模块.'

  s.homepage         = 'https://gitlab.v.show/ios_component/BTLiveRoom.git'
  s.author           = { 'yuxilong' => '305758560@qq.com' }
  s.license          = { type: 'MIT', file: 'LICENSE' }
  s.source           = { git: s.homepage, tag: s.version.to_s }
  s.default_subspecs = 'Core'

  s.ios.deployment_target = '15.0'
  s.static_framework      = true

  s.subspec 'Core' do |ss|
    ss.source_files = 'BTLiveRoom/Classes/**/*.{h,m}'
    ss.public_header_files = 'BTLiveRoom/Classes/BTLiveRoom.h'
    ss.private_header_files = 'BTLiveRoom/Classes/**/*.h'

    ss.prefix_header_contents = [
      '#import <Masonry/Masonry.h>',
      '#import <YYWebImage/YYWebImage.h>',
      '#import <SDWebImage/SDWebImage.h>',
      '#import <BTBaseKit/BTBaseKit.h>',
      '#import <BTLogger/BTLogger.h>',
      '#import <BTAssets/BTAssets.h>',
      '#import <BTLocalization/BTLocalization.h>',
      '#import <BTNetwork/BTNetwork.h>',
      '#import <BTToast/BTToast.h>',
      '#import <BTUserStateManager/BTUserStateManager.h>',
      '#import <BTRouter/BTRouter.h>',
      '#import <BTGlobalConfig/BTGlobalConfig.h>',
      '#import "BTLiveRoomDefines.h"',
      "static NSString *const kRoom_Bundle = @\"#{s.name.to_s}\";"
    ]
    ss.dependency 'BTLiveRoom/Resource'

  end

  s.subspec 'Resource' do |ss|
    ss.resource_bundle = { s.name.to_s => [
      'BTLiveRoom/Assets/gif/*.gif',
      'BTLiveRoom/Assets/apng/**/*.png',
      'BTLiveRoom/Assets/images/**/*.{png,jpg}',
      'BTLiveRoom/Assets/pag/**/*.{pag,png}',
      'BTLiveRoom/Assets/xcassets/*.xcassets',
      'BTLiveRoom/Assets/mp3/*.mp3',
      'BTLiveRoom/Assets/mp4/*.mp4',
      ]
    }
  end

  s.dependency 'pop'
  s.dependency 'MMKV'
  s.dependency 'YYText'
  s.dependency 'YYImage'
  s.dependency 'YYWebImage'
  s.dependency 'SDWebImage'
  s.dependency 'libpag'
  s.dependency 'JXCategoryView-BaiTu'
  s.dependency 'DZNEmptyDataSet'
  s.dependency 'MJRefresh'

  s.dependency 'BTNetwork'
  s.dependency 'BTBaseKit'
  s.dependency 'BTRtcEngine'
  s.dependency 'BTRTLAdapter'
  s.dependency 'BTAssets'
  s.dependency 'BTLocalization'
  s.dependency 'BTToast'
  s.dependency 'BTUserStateManager'
  s.dependency 'BTMQTT'
  s.dependency 'BTRouter'
  s.dependency 'BTAlphaVideoPlayer'
  s.dependency 'BTComponentsKit'
  s.dependency 'BTGlobalConfig'
  s.dependency 'BTLogger'
  s.dependency 'BTUserInfo'
  s.dependency 'BTProtobufMessages'

  s.test_spec 'Tests' do |test_spec|
    test_spec.requires_app_host = true
    test_spec.source_files = 'BTLiveRoom/Tests/**/*.{h,m}'
  end

end
