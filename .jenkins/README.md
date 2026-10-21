# 发版环境

公开仓库默认由 `.github/workflows/release.yml` 在 main 推送或手动触发时发版，使用 Ruby 3.3、Bundler 2.5.23。完整回归失败会阻止发布。版本提交包含 `[skip ci]`，避免重复触发。

Actions 和 Jenkins 共用 `.jenkins/release.sh`：递增源码及锁文件版本、构建 gem、创建预发布存档、上传到 `v2.2.0` 固定资产桶，并清理桶内本插件旧 gem。Actions 在发布成功后通过 `LARK_BOT_WEB_HOOK_URL` 发送 Lark 通知，不自动触发其他 Jenkins 任务。

Jenkins 的 `release-cocoapods-publish` 保留为手动备用，关闭 SCM 轮询，默认 `DRY_RUN=true`。不要与 Actions 同时正式发布。验证构建不提交版本、不上传、不更新工具链、不通知。

Jenkins 仅在本任务 PATH 中优先选择 Homebrew Ruby 3.3，并将 Bundler 和依赖安装到工作区 `.jenkins-output/`；不改变节点全局 Ruby、gem 或其他任务配置。需要预装 `/opt/homebrew/opt/ruby@3.3` 或 `/usr/local/opt/ruby@3.3`，Git、gh 和 Xcode 命令行工具。

Pipeline from SCM 使用本仓库 main、`.jenkins/Jenkinsfile`。手动正式发版仍沿用 `github-release`、`lark-release-webhook` 凭据和原有工具链更新、通知步骤；日常发版使用 Actions。

验证：`bash -n .jenkins/release.sh`、`ruby .jenkins/test_release.rb`、`bundle exec rake specs`。发布脚本在 main 已前进时停止；失败后先检查版本提交、Release 和资产桶状态再重试，避免重复递增。
