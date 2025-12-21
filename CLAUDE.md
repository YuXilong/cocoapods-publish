# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

cocoapods-publish 是一个 CocoaPods 插件，用于自动发布 iOS 组件到私有仓库（BaiTuPods 源码仓库、BaiTuFrameworkPods 二进制仓库）。支持源码版本、二进制 Framework 版本和代码混淆版本的自动化发布。

## 常用命令

```bash
# 安装依赖
bundle install

# 运行测试
bundle exec bacon spec/**/*_spec.rb
# 或
rake spec

# 代码检查
bundle exec rubocop
```

## 核心架构

### 命令模块 (`lib/pod/command/`)
- **publish.rb** - 主发布命令，处理版本号递增、podspec 验证、Git 标签管理、仓库推送
- **auto.rb** - 自动化发布，一键打包生成二进制并同时发布源码和二进制版本

### 工具模块 (`lib/cocoapods-publish/`)
- **pod_utils.rb** - 沙箱构建、Pod 依赖安装、Podfile 生成
- **repo_utils.rb** - `PushWithoutValid` 类实现跳过验证的推送
- **gitlab_utils.rb** - GitLab API 交互（项目创建、远程仓库管理）
- **podfile_dsl.rb** - 自定义 DSL（baitu_dependencies, baitu_use_frameworks!, baitu_mixup_module!）

### 钩子系统 (`lib/hooks/`)
CocoaPods 生命周期钩子，在安装过程中执行自定义逻辑：
- **auto_switch_source_hook.rb** - pre_install/source_provider 钩子，处理源码/二进制模式切换和缓存管理
- **installer.rb** - 扩展 Pod::Installer，支持 Podfile.local、Swift 版本检测
- **dependency.rb** - 扩展 Pod::Dependency，Swift 版本自适应、混淆支持
- **podfile.rb** - 扩展 Pod::Podfile，设置默认部署目标（iOS 13.0）
- **version.rb** - 扩展 Pod::Version，处理 .swift 后缀版本号

### 插件入口
- **lib/cocoapods_plugin.rb** - 导入所有模块和钩子
- **lib/cocoapods-publish.rb** - 版本定义（当前 2.7.5）

## 发布流程

```
命令解析 → 版本号处理 → podspec 验证 (pod lib lint)
    → GitLab 仓库检查/创建 → Git 标签创建推送 → 私有仓库发布
```

## 关键特性
- 多源支持（trunk, BaiTuPods, BaiTuFrameworkPods）
- 自动版本号递增、Beta 版本、Swift 版本标签
- 二进制 Framework 发布（vendored_frameworks）
- 代码混淆变体发布
- Subspecs 独立发布
- Podfile.local 本地依赖覆盖
- 源码/二进制缓存自动切换

## 环境变量
- `GIT_LAB_HOST` - GitLab 服务器地址
- `GIT_LAB_TOKEN` - GitLab API 令牌
- `USE_FRAMEWORK` - 启用二进制模式
