# Created by yuxilong on 2026/10/15.
require 'cocoapods-publish/reer_macro_preparation'
module Pod
  module Publish
    module SwiftMacroIntegration
      # 只传递已支持组件的宿主插件，不传播其余任意编译选项。
      PLUGINS = { 'ReerCodable' => 'ReerCodableMacros', 'BTLogger' => 'BTLoggerMacroPlugin' }.freeze

      def self.apply(installer)
        results = installer.target_installation_results
        return unless results

        results.pod_target_installation_results.each_value do |result|
          ReerMacroPreparation.integrate(result)
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
              macros = dependencies.flat_map do |dependency|
                plugin = PLUGINS[dependency.root_spec.name]
                next [] unless plugin

                # 使用已安装规格的路径；旧版没有宏配置时保持原行为。
                flags = dependency.root_spec.consumer(dependency.platform).pod_target_xcconfig['OTHER_SWIFT_FLAGS'].to_s
                flags.scan(/-load-plugin-executable\s+(?:"[^"]+"|'[^']+'|\S+)/).select do |flag|
                  flag.match?(/\##{Regexp.escape(plugin)}["']?\z/)
                end
              end
              next if macros.empty?

              settings = config.build_settings
              current = Array(settings['OTHER_SWIFT_FLAGS']).join(' ')
              missing = macros.uniq.reject { |macro| current.include?(macro) }
              next if missing.empty?

              # target 级设置不能遮盖 CocoaPods xcconfig 或使用方自己的编译参数。
              inherited = current.include?('$(inherited)') || current.include?('${inherited}')
              settings['OTHER_SWIFT_FLAGS'] = [inherited ? nil : '$(inherited)', current, *missing].compact.reject(&:empty?).join(' ')
            end
          end
        end
      end
    end
  end
end
