# Created by yuxilong on 2026/10/28.
require_relative '../../scripts/reer_macro_cache'

module Pod
  module Publish
    module ReerMacroPreparation
      def self.prepare(installer)
        installer.pod_targets.select { |target| target.root_spec.name == 'ReerCodable' }.uniq { |target| target.root_spec.version }.each do |target|
          phase = target.root_spec.consumer(target.platform).script_phases.find { |item| item[:name] == 'Prepare ReerCodable macro' }
          next unless phase

          version = target.root_spec.version.to_s
          raise Informative, 'Invalid ReerCodable version' unless version.match?(/\A\d+(?:\.\d+)*\z/)

          directory = installer.sandbox.root.join('.cocoapods-publish', 'ReerCodable', version)
          FileUtils.mkdir_p(directory)
          script = directory.join('download.sh')
          File.write(script, phase.fetch(:script))
          FileUtils.cp(File.expand_path('../../scripts/reer_macro_cache.rb', __dir__), directory.join('prepare.rb'))
          ReerMacroCache.prepare(script.to_s, version)
        end
      rescue RuntimeError => error
        raise Informative, error.message
      end

      def self.integrate(result)
        return unless result.target.root_spec.name == 'ReerCodable'

        result.native_target.shell_script_build_phases.each do |phase|
          next unless phase.name == '[CP-User] Prepare ReerCodable macro'

          version = result.target.root_spec.version.to_s
          # Fastlane/bundle exec 的 Ruby 环境不能传给系统 Ruby；helper 只用标准库。
          phase.shell_script = "/usr/bin/env -u RUBYOPT -u RUBYLIB -u GEM_HOME -u GEM_PATH /usr/bin/ruby \"${PODS_ROOT}/.cocoapods-publish/ReerCodable/#{version}/prepare.rb\" #{version}"
          phase.always_out_of_date = '1'
        end
      end
    end
  end
end
