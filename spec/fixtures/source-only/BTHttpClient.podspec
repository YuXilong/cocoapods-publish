# Created by yuxilong on 2026/10/20.
# 源码规格草案；二进制规格由发布插件生成，现有插件适配后再替换原文件。
Pod::Spec.new do |s|
  s.name             = 'BTHttpClient'
  s.version          = '99'
  s.summary          = '网络模块.'
  s.description      = '提供网络请求相关服务.'
  s.homepage         = 'https://gitlab.v.show/ios_component/Dora/Common/BTHttpClient.git'
  s.author           = { 'yuxilong' => '305758560@qq.com' }
  s.license          = { type: 'MIT', file: 'LICENSE' }
  s.source           = { git: s.homepage, tag: s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.static_framework = true
  # 源码含参数列表尾逗号，源码接入需要 Xcode 16.3+。
  s.swift_version = '6.0'

  s.source_files = 'BTHttpClient/**/*.swift'
  s.vendored_frameworks = 'BTHttpClient/Vender/*.xcframework'
  s.frameworks = 'UIKit', 'Foundation', 'CoreTelephony', 'AVFoundation', 'SystemConfiguration'
  s.libraries = 'c++'

  # 保留现有架构及 Bitcode 配置，避免本次结构简化改变编译行为。
  s.pod_target_xcconfig = {
    # OC 宿主会从后台线程调用服务，保留现有的动态隔离检查设置。
    # shortcut: OC 侧并发访问沿用旧实现不加锁，需要严格隔离时改为 nonisolated 入口并切主线程。
    'OTHER_SWIFT_FLAGS' => '$(inherited) -Xfrontend -disable-dynamic-actor-isolation'
  }

  s.dependency 'Alamofire', '~> 5.10'
  s.dependency 'BTLogger'
  s.dependency 'BTBaseKit'
  s.dependency 'BTDContext'
  s.dependency 'BTRouter'
  s.dependency 'SmAntiFraud', '3.13.1'
  s.dependency 'MMKV'
  # Swift 接口不写模型类型时返回 SwiftyJSON 的 JSON；沿用现有 5.x 约束。
  s.dependency 'SwiftyJSON', '~> 5.0'
end
