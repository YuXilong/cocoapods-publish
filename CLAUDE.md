# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

cocoapods-publish 是一个 CocoaPods 插件，用于自动发布组件到私有组件仓库。主要功能包括：

- 自动发布源码/二进制组件到私有仓库
- 源码与二进制模式自动切换
- 支持代码混淆发布
- 支持 Swift 版本管理
- 支持 beta 版本发布
- 自动创建 GitLab 仓库
- Podfile.local 本地覆盖支持

## 常用命令

```bash
# 安装依赖
bundle install

# 运行测试
bundle exec rake specs

# 本地安装插件
bundle exec rake install

# 发布到 RubyGems
bundle exec rake release
```

### 使用插件命令

```bash
# 发布组件到私有仓库
pod publish REPO_NAME POD_SPEC_FILE

# 一键打包发布
pod publish auto [NAME.podspec] [options]
```

## 代码架构

### 核心入口
- `lib/cocoapods_plugin.rb` - 插件入口，加载所有模块
- `lib/cocoapods-publish.rb` - 版本定义

### 命令模块 (lib/pod/command/)
- `publish.rb` - 主发布命令，处理版本管理、验证、推送等
- `auto.rb` - 一键打包发布命令，整合打包和发布流程

### 工具模块 (lib/cocoapods-publish/)
- `pod_utils.rb` - Pod 构建相关工具（Sandbox、Installer、动态库构建等）
- `repo_utils.rb` - 仓库推送工具（PushWithoutValid 跳过验证直接推送）
- `gitlab_utils.rb` - GitLab API 交互（项目创建、ID查询等）
- `podfile_dsl.rb` - Podfile DSL 扩展（baitu_use_frameworks!、baitu_mixup_module!）

### Hook 模块 (lib/hooks/)
- `auto_switch_source_hook.rb` - 源码/二进制缓存自动切换（pre_install、source_provider hook）
- `installer.rb` - 安装器扩展（Podfile.local 支持、混淆源地址动态修改、Swift 版本检测）
- `dependency.rb` - 依赖处理扩展（Swift 版本自动绑定、混淆库支持）
- `version.rb` - 版本号处理扩展（.swift 后缀兼容）
- `podfile.rb` - Podfile 后处理（部署目标、签名配置）
- `project.rb` - 项目扩展（Podfile.local 添加到项目）

## 关键配置

### 环境变量
- `USE_FRAMEWORK` - 设为 '1' 启用二进制模式
- `GIT_LAB_HOST` - GitLab 服务器地址
- `GIT_LAB_TOKEN` - GitLab API Token
- `USE_DEV_FRAMEWORK_<NAME>` - 指定组件使用开发版本

### Podfile DSL 扩展

```ruby
plugin 'cocoapods-publish'

# 启用二进制模式
baitu_use_frameworks!

# 启用混淆模块
baitu_mixup_module!('MODULE_NAME')
```

## 版本号规则

- 基础版本：`1.0.0`
- Beta 版本：`1.0.0.b1`
- Swift 版本：`1.0.0.swift-5.9`
- 分支版本：`1.0.0.BRANCH_NAME`
- 混淆版本：`1.0.0.MNL-C`（类混淆）、`1.0.0.MNL-CF`（类+函数混淆）、`1.0.0.MNL-SC`（subspec+类）

## 开发注意事项

- 代码遵循 Ruby/CocoaPods 风格
- 使用 alias 方式扩展 CocoaPods 原生类方法
- Hook 注册使用 `Pod::HooksManager.register`
- 日志输出使用 `puts` 配合 `.yellow`/`.green`/`.red` 颜色
