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
