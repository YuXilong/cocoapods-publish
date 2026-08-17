module Pod
  class Dependency
    # swift 版本按天缓存到 /tmp，避免每次 require 都起子进程
    def self.cached_swift_version
      cache_file = "/tmp/.cocoapods_swift_ver_#{Time.now.strftime('%Y-%m-%d')}"
      return File.read(cache_file).strip if File.exist?(cache_file)

      ver = Open3.popen3('swift --version')[1].gets.to_s
                 .gsub(/version (\d+(\.\d+)+)/).to_a[0].to_s.split(' ')[1].to_s
      File.write(cache_file, ver) unless ver.empty?
      ver
    end

    SWIFT_VERSION = cached_swift_version
    LEGACY_SWIFT_VERSION_PATTERN = /\.swift-(?<compiler>\d+(?:\.\d+)*)\z/.freeze
    VERSION_REQUIREMENT_OPERATOR_PATTERN = /[<>=~]/.freeze
    YYIMAGE_LEGACY_VERSION = '1.0.4'.freeze
    YYIMAGE_SIMULATOR_VERSION = '1.0.4.BAITU'.freeze

    alias origin_initialize initialize

    # 混淆支持
    FW_MIXUP_SUPPORT = %w[VO MNL PPL ZSL PAS PLA MTI MIU VO_Framework MNL_Framework PPL_Framework ZSL_Framework PAS_Framework PLA_Framework MTI_Framework MIU_Framework].freeze

    def initialize(name = nil, *requirements)
      return origin_initialize(name, *requirements) if name.nil? || name.empty?

      if requirements.last.is_a?(Hash) && requirements.last.keys.first == :path
        Dependency.source_dependency[name] = requirements.last[:path]
      end

      base_name = name.split('/').first
      if yyimage_simulator_requirement?(base_name, requirements)
        requirements = [YYIMAGE_SIMULATOR_VERSION, Installer::YYIMAGE_FORK_SOURCE.dup]
      end
      if name.start_with?('BT') &&
         !requirements.last.is_a?(Hash) &&
         (explicit_legacy_requirement?(requirements) || legacy_swift_framework?(base_name))
        if name.include?('/')
          unless FW_MIXUP_SUPPORT.filter { |prefix| name == "#{base_name}/#{prefix}" }.empty?
            requirements = [genrate_requirements(base_name, requirements)]
          end
        else
          requirements = [genrate_requirements(name, requirements)]
        end
      end

      origin_initialize(name, *requirements)
    end

    def yyimage_simulator_requirement?(base_name, requirements)
      return false unless base_name == 'YYImage'

      # YYWebImage 等传递依赖通常只声明 YYImage、不带版本。如果放任 CocoaPods
      # 先从 trunk 选中公开版，后续 YYImage/WebP 无法再切到同名私有 Specs。
      return true if requirements.empty?
      return false unless requirements.one?

      requirement = requirements.first
      if requirement.is_a?(Array)
        return true if requirement.empty?

        requirement = requirement.first if requirement.one?
      end
      return false unless requirement.is_a?(String)

      normalized_requirement = requirement.strip.sub(/\A=\s*/, '')
      [YYIMAGE_LEGACY_VERSION, YYIMAGE_SIMULATOR_VERSION].include?(normalized_requirement)
    end

    def explicit_legacy_requirement?(requirements)
      requirements.any? do |requirement|
        requirement.is_a?(String) && LEGACY_SWIFT_VERSION_PATTERN.match?(requirement)
      end
    end

    def genrate_requirements(name, requirements)
      return requirements if requirements.empty?

      # 获取当前的版本号
      version = requirements[0]

      # 其它地方已指定版本号，本次不自动指定版本号，比如在podspec中依赖通常不指定版本号 在podfile中会指定对应的版本号
      if version.is_a?(Array) && Dependency.specified_framework_versions.keys.include?(name)
        return Dependency.specified_framework_versions[name]
      end

      # 已自动指定版本号
      version = Dependency.modified_frameworks[name] if Dependency.modified_frameworks.keys.include?(name)

      is_specified = !version.is_a?(Array)

      # 未指定版本号
      version = local_framework_version(name) if version.is_a?(Array)

      return version if version.is_a?(Array)

      version = compatible_framework_version(name, version.to_s)

      # 存储自动指定的版本号
      Dependency.modified_frameworks[name] = version unless Dependency.modified_frameworks.keys.include?(name)

      # 存储已指定的版本号
      if is_specified && !Dependency.specified_framework_versions.keys.include?(name)
        Dependency.specified_framework_versions[name] = version
      end

      # 重新指定版本
      version
    end

    def self.modified_frameworks
      @@modified_frameworks ||= {}
    end

    def self.specified_framework_versions
      @@specified_framework_versions ||= {}
    end

    def self.source_dependency
      @@source_dependenc ||= {}
    end

    # local_framework_version 按组件名 memoize
    def self.local_version_cache
      @@local_version_cache ||= {}
    end

    def self.legacy_swift_framework_cache
      @legacy_swift_framework_cache ||= {}
    end

    # 新版本由 CocoaPods 正常解析；只有存在历史 Swift 后缀时才启用兼容转换。
    def legacy_swift_framework?(framework_name)
      return false if framework_name.nil? || SWIFT_VERSION.empty?

      cache = Dependency.legacy_swift_framework_cache
      return cache[framework_name] if cache.key?(framework_name)

      cache[framework_name] = framework_spec_paths(framework_name).any? do |spec_file|
        version = Pathname(spec_file).parent.basename.to_s
        match = LEGACY_SWIFT_VERSION_PATTERN.match(version)
        match && match[:compiler] == SWIFT_VERSION
      end
    end

    def local_framework_version(fw)
      # 获取通过MIN_SWIFT_DEPENDENCY_VERSION指定的版本号
      version = get_min_dependency_version(fw)
      return compatible_framework_version(fw, version) unless version.nil?

      cache = Dependency.local_version_cache
      return cache[fw] if cache.key?(fw)

      folder_paths = compatible_framework_spec_paths(fw)

      # 使用File.mtime获取每个文件夹的修改日期并进行排序
      if folder_paths.empty?
        cache[fw] = []
        return cache[fw]
      end

      spec_file = folder_paths.max_by { |folder| local_framework_version_sort_key(folder) }
      spec = Specification.from_file(spec_file)
      cache[fw] = spec.attributes_hash['version']
    end

    def local_framework_version_sort_key(spec_file)
      version = Pathname(spec_file).parent.basename.to_s
      stable_priority = LEGACY_SWIFT_VERSION_PATTERN.match?(version) ? 0 : 1
      semantic_version = version.sub(LEGACY_SWIFT_VERSION_PATTERN, '')
      base_version, beta_version = semantic_version.split('.b', 2)
      numeric_segments = base_version.scan(/\d+/).map(&:to_i)
      beta_priority = beta_version.nil? ? 0 : 1
      beta_number = beta_version.to_s[/\A\d+/].to_i

      [numeric_segments, beta_priority, beta_number, stable_priority, semantic_version]
    end

    def compatible_framework_version(framework_name, version)
      if version.match?(VERSION_REQUIREMENT_OPERATOR_PATTERN)
        return compatible_version_for_requirement(framework_name, version)
      end

      legacy_match = LEGACY_SWIFT_VERSION_PATTERN.match(version)
      base_version = legacy_match ? version.sub(LEGACY_SWIFT_VERSION_PATTERN, '') : version
      return base_version if framework_version_exists?(framework_name, base_version)

      legacy_version = "#{base_version}.swift-#{SWIFT_VERSION}"
      if !SWIFT_VERSION.empty? && framework_version_exists?(framework_name, legacy_version)
        return legacy_version
      end

      # 不继续选择其它编译器生成的二进制，让 CocoaPods 明确报告版本不可用。
      legacy_match ? base_version : version
    end

    def compatible_version_for_requirement(framework_name, version_requirement)
      requirement = Requirement.new(version_requirement)
      spec_file = compatible_framework_spec_paths(framework_name).select do |candidate|
        artifact_version = Pathname(candidate).parent.basename.to_s
        semantic_version = artifact_version.sub(LEGACY_SWIFT_VERSION_PATTERN, '')
        requirement.satisfied_by?(Version.new(semantic_version))
      end.max_by { |candidate| local_framework_version_sort_key(candidate) }
      return version_requirement if spec_file.nil?

      Specification.from_file(spec_file).attributes_hash['version']
    rescue ArgumentError
      version_requirement
    end

    def compatible_framework_spec_paths(framework_name)
      framework_spec_paths(framework_name).select do |spec_file|
        version = Pathname(spec_file).parent.basename.to_s
        match = LEGACY_SWIFT_VERSION_PATTERN.match(version)
        match.nil? || match[:compiler] == SWIFT_VERSION
      end
    end

    def framework_spec_paths(framework_name)
      base_fw = framework_name.split('/').first
      repo = File.join(Pod::Config.instance.repos_dir.to_s, 'BaiTuFrameworkPods')
      Dir.glob(File.join(repo, base_fw, '*', "#{base_fw}.podspec")).select { |entry| File.file?(entry) }
    end

    def framework_version_exists?(framework_name, version)
      base_fw = framework_name.split('/').first
      repo = File.join(Pod::Config.instance.repos_dir.to_s, 'BaiTuFrameworkPods')
      File.file?(File.join(repo, base_fw, version, "#{base_fw}.podspec"))
    end

    # 获取指定的版本号
    def get_min_dependency_version(fw_name)
      regex = /^(?m)MIN_SWIFT_DEPENDENCY_VERSION\s*=\s*\[(?<SWIFT_DEPENDENCY>.*?)\]/
      Dependency.source_dependency.each do |key, val|
        file_path = "#{val}/#{key}.podspec"
        next unless File.exist?(file_path)

        content = File.read(file_path).to_s
        content.scan(regex) do
          # 直接获取命名捕获组 SWIFT_DEPENDENCY
          dependency_str = Regexp.last_match[:SWIFT_DEPENDENCY].strip
          # 分割为版本条目
          versions = dependency_str.split(',').map(&:strip).reject(&:empty?)

          versions.each do |v|
            name = v.split('=>')[0].gsub("'", '').strip
            return v.split('=>')[1]&.gsub("'", '')&.strip || nil if name == fw_name
          end
        end
      end
      nil
    end
  end

end
