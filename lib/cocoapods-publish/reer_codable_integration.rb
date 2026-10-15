# Created by yuxilong on 2026/10/15.
module Pod
  module Publish
    module ReerCodableIntegration
      def self.apply(installer)
        results = installer.target_installation_results
        return unless results

        results.pod_target_installation_results.each_value do |result|
          target = result.target
          targets = { result.native_target => nil }.merge(result.non_library_specs_by_native_target)
          targets.each do |native_target, spec|
            next unless native_target

            native_target.build_configurations.each do |config|
              configuration = target.user_build_configurations.fetch(config.name)
              dependencies = if spec&.test_specification?
                               target.dependent_targets_for_test_spec(spec, :configuration => configuration)
                             elsif spec&.app_specification?
                               target.dependent_targets_for_app_spec(spec, :configuration => configuration)
                             else
                               target.recursive_dependent_targets(:configuration => configuration)
                             end
              dependency = dependencies.find { |pod| pod.root_spec.name == 'ReerCodable' }
              next unless dependency

              # 使用已安装规格的路径和版本；旧版没有预编译宏配置时保持原行为。
              flags = dependency.root_spec.consumer(dependency.platform).pod_target_xcconfig['OTHER_SWIFT_FLAGS'].to_s
              macro = flags.scan(/-load-plugin-executable\s+(?:"[^"]+"|'[^']+'|\S+)/).find do |flag|
                flag.match?(/#ReerCodableMacros["']?\z/)
              end
              next unless macro

              settings = config.build_settings
              current = Array(settings['OTHER_SWIFT_FLAGS']).join(' ')
              next if current.include?(macro)

              # target 级设置不能遮盖 CocoaPods xcconfig 或使用方自己的编译参数。
              inherited = current.include?('$(inherited)') || current.include?('${inherited}')
              settings['OTHER_SWIFT_FLAGS'] = [inherited ? nil : '$(inherited)', current, macro].compact.reject(&:empty?).join(' ')
            end
          end
        end
      end
    end
  end
end
