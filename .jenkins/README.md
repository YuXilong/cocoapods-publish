# 本地 Jenkins 发布

任务 `release-cocoapods-publish` 在本地 `local-release` 节点构建 gem，每 5 分钟轮询 `main`。GitHub 只存源码和发布资产。

Pipeline from SCM：`https://github.com/YuXilong/cocoapods-publish.git`，分支 `*/main`，凭据 `github-release`，Script Path `.jenkins/Jenkinsfile`。Git MessageExclusion 设置为 `(?s)^chore: bump .*`，排除自动版本提交，避免循环发布。首次手动验证后轮询生效。

凭据：`github-release` 为 Username with password（GitHub 用户/token，具备本仓库和固定资产桶写权限）；`lark-release-webhook` 为 Secret text（飞书 webhook）。正式发布前先检查通知凭据。节点需要 Ruby 3+、Git、gh、jq，Bundler 按 Gemfile.lock 安装依赖。

参数 `VERSION_BUMP` 默认为 patch，支持 minor/major；`DRY_RUN=true` 只测试、构建并归档 gem，不提交版本、不上传、不触发更新、不通知。

交付保留原流程：递增源码和锁文件版本、创建 prerelease、上传至 `YuXilong/cocoapods-publish` 的 `v2.2.0` 固定资产桶、成功后清理本插件旧 gem、异步触发“更新构建工具链”、发送飞书通知。原 Actions 的非阻断 specs 策略继续保留，测试失败会在日志中显示。

本地检查：`bash -n .jenkins/release.sh`、`ruby .jenkins/test_release.rb`。后者使用假构建命令验证版本进位和 dry-run 不触发远端写入。

若构建期间 main 前进，发布停止并要求重跑。远端发布不是事务；失败后检查版本提交、Release 和固定资产桶，重跑可能继续递增版本。不强推、不覆盖已有 Tag。停用 Jenkins 任务可暂停发布；恢复旧 Actions 前先停用 Jenkins，避免重复发布。

本机节点由用户级 launchd 服务 `com.wukong.jenkins-release-agent` 保持连接，工作目录为 `/Users/yuxilong/.jenkins/release-agent`。控制器仍为 0 执行器，现有 iOS 构建节点不承担这些发布任务。本机节点保持单执行器，使跨仓库发布及 Homebrew 更新串行。电脑需保持开机、用户会话及 Jenkins 服务在线。
