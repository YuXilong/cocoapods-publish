# frozen_string_literal: true

module Pod
  class Installer
    alias origin_resolve_dependencies resolve_dependencies
    alias origin_initialize initialize
    alias origin_integrate_user_project integrate_user_project

    # swift 版本按天缓存到 /tmp，与 dependency.rb 共用同一缓存文件，避免二次起进程
    def self.cached_swift_version
      cache_file = "/tmp/.cocoapods_swift_ver_#{Time.now.strftime('%Y-%m-%d')}"
      return File.read(cache_file).strip if File.exist?(cache_file)

      ver = Open3.popen3('swift --version')[1].gets.to_s
                 .gsub(/version (\d+(\.\d+)+)/).to_a[0].to_s.split(' ')[1].to_s
      File.write(cache_file, ver) unless ver.empty?
      ver
    end

    SWIFT_VERSION = cached_swift_version

    def initialize(sandbox, podfile, lockfile = nil)
      # podfile.dependencies.each { |dep| dep.covert_swift_necessnary }
      # config.podfile.dependencies.each { |dep| dep.covert_swift_necessnary }

      # 多仓库同名称警告关闭
      podfile.installation_options.warn_for_multiple_pod_sources = false
      podfile.installation_options.warn_for_unused_master_specs_repo = true
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

      # Texture<3.2.0 的 spec source 替换为含 PR #2032 的官方 3.2.0 tag（源码/二进制模式都生效）
      patch_texture_source

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
      local_dependencies&.each do |dep|
          dep.each do |name, _|
            removed = dependencies.reject! do |item|
              item == name || (item.is_a?(Hash) && item.keys.map { |k| k.split('/')[0] }.include?(name))
            end
            # dependencies << dep if removed
            dependencies << dep
            ENV["USE_DEV_FRAMEWORK_#{name}"] = '1' if removed
          end
        end

      internal_hash['dependencies'] = dependencies
      @podfile.target_definitions[project_def.label.gsub('Pods-', '')].instance_variable_set(:@internal_hash, internal_hash)
    end

    # Texture（AsyncDisplayKit）< 3.2.0 主线程自锁修复
    #
    # 3.1.0 在 load 时的构造函数里于主线程创建 UIView 读取 UIKit 图层默认值，
    # 触发 +[UIScreen initialize] 的 dispatch_once 等待 app 初始化上下文 → 主线程自锁，
    # 跑 Tests 时永久卡死。官方 PR #2032（3.2.0 起合入）把碰 UIKit 的代码从 constructor
    # 挪到 destructor 修复此问题，但 3.2.0 未发布到公共 CocoaPods，默认仍装 3.1.0。
    #
    # 这里在依赖解析后集中把 Texture 的 spec source 替换为含修复的 git tag，
    # 保留自动初始化（无需各 app 手动 init），源码/二进制模式都生效，pod install 时集中修复。
    # 目标按"本地是否配置了 BaiTu-iOS/baitu-specs 私有源"二选一：
    #   有 → 用我们 fork 的 3.1.0.BAITU（与自有版本体系一致、差异最小）
    #   无 → 回退官方 3.2.0 tag（公网可达）
    # NO_TEXTURE_PATCH=1 可关闭。
    TEXTURE_VERSION_FIXED = '3.2.0'   # >= 此版本视为已含修复，跳过
    TEXTURE_FORK_SOURCE = { git: 'https://github.com/BaiTu-iOS/Texture.git', tag: '3.1.0.BAITU' }.freeze
    TEXTURE_OFFICIAL_SOURCE = { git: 'https://github.com/TextureGroup/Texture.git', tag: '3.2.0' }.freeze
    BAITU_SPECS_MARK = 'baitu-specs'

    def patch_texture_source
      return if ENV['NO_TEXTURE_PATCH'] == '1'

      target = baitu_specs_available? ? TEXTURE_FORK_SOURCE : TEXTURE_OFFICIAL_SOURCE

      analysis_result.specifications.each do |spec|
        root = spec.root
        next unless root.name == 'Texture'
        # 已是 3.2.0+（含修复，可能用户已自行指定）则跳过，幂等
        next unless root.version < Pod::Version.new(TEXTURE_VERSION_FIXED)
        # 本地开发版 Texture 不动，避免覆盖用户本地调试
        next if @sandbox.development_pods.key?(root.name)
        # 已经指向目标 tag 则跳过
        src = root.source || {}
        next if src[:git] == target[:git] && src[:tag] == target[:tag]

        root.source = target.dup
        puts "[cocoapods-publish] Texture #{root.version} 含主线程自锁缺陷，已替换 source → #{target[:git]} @ #{target[:tag]}（避免测试卡死）".yellow
      end
    rescue StandardError => e
      puts "[cocoapods-publish] Texture source 替换跳过：#{e.message}".red
    end

    # 检测本地是否配置了 BaiTu-iOS/baitu-specs 私有 spec 源：
    # 1) Podfile 通过 source 'xxx/baitu-specs.git' 声明；2) 已安装到 ~/.cocoapods/repos 的 spec repo。
    def baitu_specs_available?
      podfile_sources = (@podfile.sources rescue nil) || []
      return true if podfile_sources.any? { |s| s.to_s.downcase.include?(BAITU_SPECS_MARK) }

      repos_dir = File.expand_path('~/.cocoapods/repos')
      return false unless File.directory?(repos_dir)

      Dir.glob(File.join(repos_dir, '*')).any? do |repo|
        cfg = File.join(repo, '.git', 'config')
        File.file?(cfg) && File.read(cfg).downcase.include?(BAITU_SPECS_MARK)
      end
    rescue StandardError
      false
    end

    # 根据混淆模式动态修改对应地址
    def check_http_source
      host = (ENV['GIT_LAB_HOST']).to_s.freeze
      analysis_result.specifications.filter { |spec| spec.name.start_with?('BT') }.each do |spec|
        name = spec.attributes_hash['name']
        # 迁移域名（匹配所有 .v.show 结尾的域名）
        spec.root.source[:http].gsub!(/[a-zA-Z0-9_.-]+\.v\.show/, host) if spec.root.source[:http] && spec.root.source[:http].strip != ''
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
        # 迁移域名（匹配所有 .v.show 结尾的域名）
        http.gsub!(/[a-zA-Z0-9_.-]+\.v\.show/, host) if http.strip != ''
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
