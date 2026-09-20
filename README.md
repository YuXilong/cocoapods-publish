# cocoapods-publish

自动发布组件到私有组件仓库

## Installation

    $ gem install cocoapods-publish

## Usage

    $ pod publish REPO_NAME POD_SPEC_FILE

### 依赖版本预检

默认的 `pod install` 不执行额外预检。需要一次性检查 Podfile 中所有找不到的直接依赖版本时执行：

    $ pod install --precheck

未开启预检且 CocoaPods 只报告单个缺失版本时，错误信息会提示使用以上命令。

### 同仓库多 podspec 与仅二进制发布

```bash
pod publish auto --podspec=BTLoggerConsole.podspec --shared-repository=btlogger --skip-source-publish
```

`--podspec` 固定整条发布流程使用的当前目录文件。直接调用多个文件时仍支持交互选择；WuKong 负责批量枚举、排序、逐项调用及通知，每次调用都明确指定文件。

`--shared-repository=NAME` 由 WuKong 根据当前源码 `origin` 的项目名传入：复用当前源码仓库，并让 packager 上传、二进制 Specs 下载地址共用这个名称的二进制仓库。源码地址须与 origin 一致；源码标签使用 `<Pod名>-<版本>`，通过生成的源码 Specs 引用，不修改其他组件的标签。

`--skip-source-publish` 跳过源码建仓、源码 Specs 和标签发布，只自增一次版本；不能与 `--skip-framework-publish` 同时使用。二进制发布仍会把版本更新提交、推送到当前源码仓库。与新版 WuKong、cocoapods-packager 配套使用；恢复上传时保留相同选择和发布选项。
