module Pod
  class Podfile

    # 查找自定义组件依赖
    def baitu_dependencies
      dependencies.filter { |de| de.name.start_with?('BT') && de.external? }
                  .filter { |de| de.external_source[:dev] == 1 }
                  .map(&:name)
    end

    def check_envs
      baitu_dependencies.each { |name| ENV["USE_DEV_FRAMEWORK_#{name}"] = '1' }
    end

    module DSL

      # 指定使用二进制库模式
      def baitu_use_frameworks!
        ENV['USE_FRAMEWORK'] = '1'
      end

      # 指定使用的混淆模块
      def baitu_mixup_module!(name)
        ENV[name] = '1'
      end

    end

  end
end
