# frozen_string_literal: true

require 'cocoapods-publish/git_push_retry'

module Pod
  class Command
    class Repo < Command
      class Push < Repo
        # 发布Pod到仓库（去掉验证）
        class PushWithoutValid < Push
          include GitPushRetry

          def run
            check_if_push_allowed
            update_sources if @update_sources
            check_repo_status
            update_repo
            add_specs_to_repo
            push_repo unless @local_only
          end

          private

          def update_repo
            UI.puts "Updating the `#{@repo}' repo\n".yellow
            rebase_specs_repo!
          end

          def push_repo
            attempts = 1
            begin
              super
            rescue ::StandardError => e
              raise unless retry_git_push?(e, attempts)

              log_specs_push_retry(attempts)
              rebase_specs_repo!
              attempts += 1
              retry
            end
          end

          def log_specs_push_retry(attempts)
            max_retries = GitPushRetry::MAX_GIT_PUSH_ATTEMPTS - 1
            message = "检测到 Specs 仓库并发更新，拉取并 rebase 后重试 (#{attempts}/#{max_retries})"
            UI.puts message.yellow
          end

          def rebase_specs_repo!
            branch = repo_git('rev-parse', '--abbrev-ref', 'HEAD').strip
            repo_git('pull', '--rebase', 'origin', branch)
          rescue ::StandardError
            abort_specs_rebase
            raise
          end

          def abort_specs_rebase
            repo_git('rebase', '--abort')
          rescue ::StandardError
            nil
          end
        end
      end
    end
  end
end
