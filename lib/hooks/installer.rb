# frozen_string_literal: true

module Pod
  class Installer
    alias origin_resolve_dependencies resolve_dependencies
    alias origin_initialize initialize
    alias origin_integrate_user_project integrate_user_project

    SWIFT_VERSION = Open3.popen3('swift --version')[1].gets.to_s.gsub(/version (\d+(\.\d+)+)/).to_a[0].split(' ')[1]

    def initialize(sandbox, podfile, lockfile = nil)
      # podfile.dependencies.each { |dep| dep.covert_swift_necessnary }
      # config.podfile.dependencies.each { |dep| dep.covert_swift_necessnary }

      # 多仓库同名称警告关闭
      podfile.installation_options.warn_for_multiple_pod_sources = false
      origin_initialize(sandbox, podfile, lockfile)
      # 检测本地Swift版本
      check_swift_version
    end

    def check_swift_version
      lock_file = Pod::Config.instance.lockfile_path.to_s
      return unless File.exist?(lock_file)

      content = File.read(lock_file)
      swift_version = SWIFT_VERSION.gsub(/\d+\.\d+/).to_a[0].gsub('.', '').to_i
      return if swift_version >= 59 && content.include?(".swift#{SWIFT_VERSION}")

      # 移除lockfile
      @lockfile = nil if swift_version >= 59

      # 移除lockfile
      @lockfile = nil if swift_version < 59 && content.include?('.swift')
    end

    def resolve_dependencies
      # 屏蔽 "Previous definition" 警告
      original_verbose = $VERBOSE
      $VERBOSE = nil

      apply_local_podfile if local_podfile_path.exist?

      analyzer = origin_resolve_dependencies

      # 恢复警告级别
      $VERBOSE = original_verbose

      use_framework = ENV['USE_FRAMEWORK']
      check_http_source if use_framework

      analyzer
      end

    def integrate_user_project
      res = origin_integrate_user_project
      $VERBOSE = nil
      res
    end

    alias origin_clean_sandbox clean_sandbox
    def clean_sandbox
      unless @sandbox.development_pods.empty?
        # 存储本地依赖
        @sandbox.development_pods.each_key do |name|
          file = Dir.glob("#{@sandbox.root}/**/*#{name}*.json").first
          FileUtils.copy_file(file, "#{file}.bak") if file
        end
      end
      origin_clean_sandbox

      unless @sandbox.development_pods.empty?
        # 恢复本地依赖
        @sandbox.development_pods.each_key do |name|
          file = Dir.glob("#{@sandbox.root}/**/*#{name}*.json.bak").first
          File.rename(file, file.gsub('.bak', '')) if file
        end
      end
    end

    alias origin_write_lockfiles write_lockfiles
    def write_lockfiles
      origin_write_lockfiles

      unless @sandbox.development_pods.empty?
        # 移除本地依赖
        @sandbox.development_pods.each_key do |name|
          file = Dir.glob("#{@sandbox.root}/**/*#{name}*.json").first
          FileUtils.remove_file(file) if file
        end
      end
    end

      private

    def local_podfile_path
      Pathname("#{@podfile.defined_in_file}.local")
    end

    # 增加Podfile.local的支持
    def apply_local_podfile
      local_podfile = Podfile.from_ruby(local_podfile_path)
      local_pods_def = local_podfile.target_definitions['Pods']
      internal_hash_local = local_pods_def.instance_variable_get(:@internal_hash)

      # 同步platform修改
      unless local_pods_def.platform.nil?
        internal_hash = @podfile.target_definitions['Pods'].instance_variable_get(:@internal_hash)
        if internal_hash['platform'] != internal_hash_local['platform']
          internal_hash['platform'] = internal_hash_local['platform']
          @podfile.target_definitions['Pods'].instance_variable_set(:@internal_hash, internal_hash)
        end
      end

      project_def = @podfile.target_definitions.select { |k, _| k != 'Pods' && !k.include?('Tests') }.values.first
      internal_hash = project_def.instance_variable_get(:@internal_hash)
      dependencies = internal_hash['dependencies']

      # 本地版本覆盖主版本
      local_dependencies = internal_hash_local['dependencies']
      local_dependencies.each do |dep|
        dep.each do |name, _|
          removed = dependencies.reject! do |item|
            item == name || (item.is_a?(Hash) && item.keys.include?(name))
          end
          dependencies << dep if removed
          ENV["USE_DEV_FRAMEWORK_#{name}"] = '1' if removed
        end
      end

      internal_hash['dependencies'] = dependencies
      @podfile.target_definitions[project_def.label.gsub('Pods-', '')].instance_variable_set(:@internal_hash, internal_hash)
    end

    # 根据混淆模式动态修改对应地址
    def check_http_source
      analysis_result.specifications.filter { |spec| spec.name.start_with?('BT') }.each do |spec|
        name = spec.attributes_hash['name']
        clean_spec(spec)
        if name.start_with?('Core') || name.eql?(spec.root.name)
          next unless spec.root.source[:git].nil?

          spec.root.source = {
            http: spec.root.source[:http],
            type: spec.root.source[:type],
            headers: spec.root.source[:headers]
          }
          next
        end
        mix = name.gsub('_Framework', '')
        http = spec.root.source["http_#{mix}".to_sym].to_s
        if http.empty?
          http = spec.root.source[:http].to_s
          http.gsub('BT', mix)
        end

        spec.root.source = {
          http: http,
          type: spec.root.source[:type],
          headers: spec.root.source[:headers]
        }
      end
    end

      # 检查清理缓存
    def clean_spec(spec)
      cache_root = "#{Config.instance.cache_root}/Pods"
      spec_root = "#{cache_root}/Release/#{spec.root.name}"

      name = spec.attributes_hash['name']
      name = 'BT' if name.start_with?('Core')

      files = Dir.glob("#{spec_root}/#{spec.root.version}*/#{name}*.framework")
      unless files.count.positive?
        Dir.glob("#{spec_root}/#{spec.root.version}*/*.framework").each do |file|
          `rm -rf #{Pathname(file).parent}`
        end
      end
    end

    end
  end
