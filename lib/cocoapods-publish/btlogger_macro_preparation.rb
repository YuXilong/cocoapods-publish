# Created by yuxilong on 2026/10/29.
require_relative '../../scripts/btlogger_macro_cache'

module Pod
  module Publish
    module BTLoggerMacroPreparation
      def self.prepare(installer)
        installer.pod_targets.select { |target|
          target.root_spec.name == 'BTLogger'
        }.uniq { |target| target.root_spec.version }.each do |target|
          phase = target.root_spec.consumer(target.platform).script_phases.find { |item|
            item[:name] == 'Build BTLogger macro'
          }
          next unless phase

          directory = installer.sandbox.root.join('.cocoapods-publish', 'BTLogger')
          FileUtils.mkdir_p(directory)
          FileUtils.cp(File.expand_path('../../scripts/btlogger_macro_cache.rb', __dir__), directory.join('prepare.rb'))
          BTLoggerMacroCache.prepare(installer.sandbox.pod_dir('BTLogger').to_s)
        end
      rescue RuntimeError, SystemCallError => error
        raise Informative, error.message
      end

      def self.integrate(result)
        return unless result.target.root_spec.name == 'BTLogger'

        result.native_target.shell_script_build_phases.each do |phase|
          next unless phase.name == '[CP-User] Build BTLogger macro'

          # 避免 Fastlane/Bundler 环境影响只依赖标准库的系统 Ruby。
          phase.shell_script = '/usr/bin/env -u RUBYOPT -u RUBYLIB -u GEM_HOME -u GEM_PATH /usr/bin/ruby "${PODS_ROOT}/.cocoapods-publish/BTLogger/prepare.rb"'
          phase.always_out_of_date = '1'
        end
      end
    end
  end
end
