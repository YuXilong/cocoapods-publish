# Created by yuxilong on 2026/10/20.
# frozen_string_literal: true
require 'json'

module Pod
  # 只转换打包时实际选中的规格；旧 CoreFramework 发布流程保持原样。
  class BinarySpecification
    SOURCE_ATTRIBUTES = %w[
      source source_files exclude_files public_header_files private_header_files
      project_header_files header_dir header_mappings_dir module_map compiler_flags
      prefix_header_file prefix_header_contents prepare_command script_phases
      resources resource_bundles vendored_frameworks vendored_libraries
      subspecs testspecs appspecs default_subspecs dependencies
    ].freeze

    def initialize(manifest)
      @manifest = manifest
    end

    def attributes
      snapshot = @manifest['specification']
      names = @manifest['selected_specs']
      unless snapshot.is_a?(Hash) && names.is_a?(Array) && !names.empty?
        raise Informative, '精简 podspec 的产物缺少构建规格，请使用新版 packager 重新打包'
      end
      root = Specification.from_hash(snapshot)
      component = @manifest.fetch('component')
      unless root.name == component['name'] && names.include?(root.name)
        raise Informative, '产物与构建规格的组件名称不一致'
      end
      specs = names.uniq.map do |name|
        spec = name == root.name ? root : root.subspec_by_name(name, false, true)
        raise Informative, "找不到构建规格：#{name}" unless spec && !spec.test_specification? && !spec.app_specification?

        spec
      end
      specs.each do |spec|
        if !spec.consumer(:ios).script_phases.empty? || spec.attributes_hash.key?('prepare_command')
          raise Informative, "#{spec.name} 含自定义脚本，需先明确二进制消费端行为"
        end
      end

      result = Marshal.load(Marshal.dump(snapshot))
      SOURCE_ATTRIBUTES.each { |key| result.delete(key) }
      %w[ios osx tvos watchos visionos].each { |key| result.delete(key) }
      result['platforms'] = { 'ios' => root.deployment_target(:ios) }
      result['name'] = component.fetch('name')
      result['version'] = component.fetch('version')
      result['module_name'] = @manifest.fetch('module_name')
      result['static_framework'] = @manifest.fetch('artifact').fetch('linkage') == 'static'
      if result['license'].is_a?(Hash)
        # LICENSE 源码路径不一定进入 ZIP，保留许可证类型/内联内容。
        result['license'].delete('file')
      end

      dependencies = {}
      specs.each do |spec|
        # 读取原始声明，避免 Dependency hook 将进程内版本缓存写入发布规格。
        [spec.attributes_hash['dependencies'], spec.attributes_hash.dig('ios', 'dependencies')].compact.each do |declarations|
          declarations.each do |name, requirements|
            if name.split('/').first == root.name
              unless names.include?(name)
                raise Informative, "内部依赖未参与构建：#{name}"
              end
              next
            end
            dependencies[name] = (Array(dependencies[name]) + Array(requirements)).uniq
          end
        end
      end
      result['dependencies'] = dependencies unless dependencies.empty?
      %w[frameworks weak_frameworks libraries].each do |key|
        values = specs.flat_map { |spec| Array(spec.consumer(:ios).public_send(key)) }.uniq
        result[key] = values unless values.empty?
      end
      %w[pod_target_xcconfig user_target_xcconfig].each do |key|
        values_by_setting = specs.each_with_object({}) do |spec, grouped|
          (spec.consumer(:ios).public_send(key) || {}).each do |setting, value|
            next if %w[VALID_ARCHS EXCLUDED_ARCHS[sdk=iphonesimulator*] ENABLE_BITCODE OTHER_SWIFT_FLAGS].include?(setting)

            (grouped[setting] ||= []) << value
          end
        end
        config = values_by_setting.each_with_object({}) do |(setting, values), merged|
          values = values.uniq
          if values.length > 1 && !Target::BuildSettings::PLURAL_SETTINGS.include?(setting)
            raise Informative, "构建规格的 #{key} 存在冲突：#{setting}"
          end
          # 与 CocoaPods 一致按完整取值去重，避免重复宏改变覆盖顺序。
          merged[setting] = values.length == 1 ? values.first : values.join(' ')
        end
        config.empty? ? result.delete(key) : result[key] = config
      end
      result['vendored_frameworks'] = [artifact_path(@manifest.fetch('artifact').fetch('path'))] +
        @manifest.fetch('vendored_frameworks').map { |path| artifact_path(path) }
      resources = @manifest.fetch('resources').map { |resource| artifact_path(resource.fetch('path')) }
      result['resources'] = resources unless resources.empty?
      result
    rescue KeyError => e
      raise Informative, "精简 podspec 的产物元数据不完整：#{e.message}"
    end

    def render(http_url)
      data = attributes.merge('source' => { 'http' => http_url, 'type' => 'zip' })
      <<~SPEC
        # Generated from the built artifact manifest.
        Pod::Spec.from_json(<<~'PODSPEC_JSON').tap do |s|
        #{JSON.pretty_generate(data)}
        PODSPEC_JSON
          s.source = s.source.merge(:headers => ["Authorization: Bearer \#{ENV['GIT_LAB_TOKEN']}"])
        end
      SPEC
    end

    private

    def artifact_path(path)
      unless path.is_a?(String) && !path.empty? && !path.start_with?('/') &&
             !path.include?('\\') && !path.split('/').any? { |part| %w[. ..].include?(part) } &&
             !path.match?(/[\x00-\x1f*?\[\]{}]/)
        raise Informative, "产物路径无效：#{path.inspect}"
      end
      path
    end
  end
end
