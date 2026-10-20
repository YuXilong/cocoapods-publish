# cocoapods-publish

自动发布组件到私有组件仓库

## Installation

    $ gem install cocoapods-publish

## Usage

    $ pod publish REPO_NAME POD_SPEC_FILE

普通源码发布支持 podspec 的 `s.source[:git]` 使用多级 GitLab 子群组，例如 `https://gitlab-code.v.show/ios_component/Dora/Common/BTHttpClient.git`（也支持 SSH 地址）。子群组仓库须已存在且当前 token 有访问权限，按完整路径查询失败时终止，不会在顶层创建同名仓库。顶层源码仓库的自动创建、二进制仓库的查询和上传逻辑保持原有行为。

### 精简源码 podspec 的二进制发布

不含 `CoreFramework` / `*_Framework` 二进制子规格的 podspec 可以只维护源码、资源、依赖及必要编译配置。二进制发布时从新版 packager 的 artifact manifest 读取实际构建规格、选中 subspec、模块名、动态依赖和资源，生成独立的二进制 podspec；不再要求手写 ZIP 地址或二进制 subspec。旧格式优先使用原转换流程；缺少主二进制子规格或历史别名与实际产物不匹配时，使用新版 packager 记录的实际构建元数据生成。旧 manifest 没有这些字段时仍明确报错，不能凭别名猜测主产物。

精简格式必须重新打包以提供新增元数据；旧 manifest 不会被猜测补全。混淆变体使用各自构建后的组件名和资源名。源码编译声明及测试规格不会进入二进制规格，下载鉴权仍在读取 podspec 时从环境变量取得。包含自定义脚本或冲突配置时明确报错，需要先约定消费端行为。

### 依赖版本预检

默认的 `pod install` 不执行额外预检。需要一次性检查 Podfile 中所有找不到的直接依赖版本时执行：

    $ pod install --precheck

未开启预检且 CocoaPods 只报告单个缺失版本时，错误信息会提示使用以上命令。

### ReerCodable 源码组件

使用 `BaiTu-iOS/baitu-specs` 中的 ReerCodable 规格时，源码组件只需正常声明依赖：

```ruby
s.dependency 'ReerCodable', '~> 1.8'
```

安装时插件自动沿依赖图配置宏加载参数，覆盖直接依赖、传递依赖，以及组件的 test_spec/app_spec target；保留已有 Swift 参数并按 Debug/Release 的实际依赖分别处理。无需组件或业务工程另写 `OTHER_SWIFT_FLAGS`、脚本或 `post_install`。

项目仍使用现有的 `cocoapods-publish` 插件及 Specs 源。宏路径、版本和下载逻辑来自已安装的 ReerCodable 规格，插件不固定版本、不重复下载；未依赖 ReerCodable 的 Pod 和不含预编译宏配置的旧规格不受影响。当前预编译宏的 ARM Mac、Xcode 版本限制由 ReerCodable 规格决定。

### iOS 最低版本

在解析依赖前，将 Podfile 中的 iOS 最低版本统一提升到 `15.1` 下限；`Podfile.local` 的覆盖先应用，声明更高版本的 target 保留原值，其他平台不调整。生成 Pods 工程时使用同一下限，不再只依赖 `post_install` 修正。packager 的普通构建和函数混淆缓存预热共用此安装入口。

未指定版本的依赖若存在较新的纯数字稳定版，交由 CocoaPods 按平台及完整依赖图选择，不因残留历史 `.swift-*` 产物强制锁定最新版；显式版本和旧编译器产物的兼容转换保持原有行为。

### 同仓库多 podspec 与仅二进制发布

```bash
pod publish auto --podspec=BTLoggerConsole.podspec --shared-repository=btlogger --skip-source-publish
```

`--podspec` 固定整条发布流程使用的当前目录文件。直接调用多个文件时仍支持交互选择；WuKong 负责批量枚举、排序、逐项调用及通知，每次调用都明确指定文件。

`--shared-repository=NAME` 由 WuKong 根据当前源码 `origin` 的项目名传入：复用当前源码仓库，并让 packager 上传、二进制 Specs 下载地址共用这个名称的二进制仓库。源码地址须与 origin 一致；源码标签使用 `<Pod名>-<版本>`，通过生成的源码 Specs 引用，不修改其他组件的标签。

`--skip-source-publish` 跳过源码建仓、源码 Specs 和标签发布，只自增一次版本；不能与 `--skip-framework-publish` 同时使用。二进制发布仍会把版本更新提交、推送到当前源码仓库。与新版 WuKong、cocoapods-packager 配套使用；恢复上传时保留相同选择和发布选项。
