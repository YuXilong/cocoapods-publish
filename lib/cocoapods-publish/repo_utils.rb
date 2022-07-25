module Pod
  class Command
    class Repo < Command
      class Push < Repo
        # 发布Pod到仓库（去掉验证）
        class PushWithoutValid < Push

          def initialize(argv)
            super(argv)
          end

          def run
            check_if_push_allowed
            update_sources if @update_sources
            check_repo_status
            update_repo
            add_specs_to_repo
            push_repo unless @local_only
          end
        end
      end
    end
  end
  end
