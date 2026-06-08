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

      # Texture<3.2.0 主线程自锁修复：按实际用到的 subspec 注入外部源后重解析。
      # 必须放在 check_http_source 之前——重解析会重建 analysis_result，
      # 否则 check_http_source 对二进制源的改写会被丢弃。
      analyzer = reresolve_for_texture_if_needed(analyzer)

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

      patch_text_layout_chained_comparison
      patch_afnetworking_private_netinet6_header
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
    # 实现要点（关键：Texture 常是传递依赖，Podfile 里并不直接声明）：
    #   1) 先正常解析一次，从 analysis_result.specs_by_target 查出每个 target 实际
    #      用到的、未修复的 Texture subspec（如只用 Texture/Core）；
    #   2) 把这些 subspec 作为「外部源」依赖（git+tag）精确注入到对应 target，
    #      只注入用到的 subspec，绝不加根 Texture（fork 的 default_subspecs 有 6 个，会膨胀）；
    #   3) 用改过的 @podfile 重新解析，使外部源进入依赖图。
    #
    # 为何必须用「外部源 + 重解析」而非改内存 spec.source：CocoaPods 按 lockfile 的版本/
    # checksum 判定 pod 是否「变化」，只改内存 source 不会触发重新下载（日志打了但实际仍是
    # 旧 3.1.0 源码）。外部源会写入 lockfile 的 CHECKOUT OPTIONS，checkout 变化即触发重下，
    # 版本标签也随之更新为含修复版本。
    #
    # 目标按"本地是否配置了 BaiTu-iOS/baitu-specs 私有源"二选一：
    #   有 → 用我们 fork 的 3.1.0.BAITU（与自有版本体系一致、差异最小）
    #   无 → 回退官方 3.2.0 tag（公网可达）
    # 用户若已自行 pin（外部源 / 含 BAITU / >=3.2.0）则整体跳过，不与用户冲突。
    # NO_TEXTURE_PATCH=1 可关闭。
    TEXTURE_VERSION_FIXED = '3.2.0'   # >= 此版本视为已含修复，跳过
    TEXTURE_FORK_SOURCE = { git: 'https://github.com/BaiTu-iOS/Texture.git', tag: '3.1.0.BAITU' }.freeze
    TEXTURE_OFFICIAL_SOURCE = { git: 'https://github.com/TextureGroup/Texture.git', tag: '3.2.0' }.freeze
    BAITU_SPECS_MARK = 'baitu-specs'
    TEXT_LAYOUT_CHAINED_COMPARISON_RELATIVE_PATHS = [
      File.join('YYKit', 'YYKit', 'Text', 'Component', 'YYTextLayout.m'),
      File.join('YYText', 'YYText', 'Component', 'YYTextLayout.m'),
      File.join('YYText', 'YYText', 'Classes', 'Component', 'YYTextLayout.m'),
      File.join('Texture', 'Source', 'TextExperiment', 'Component', 'ASTextLayout.mm')
    ].freeze
    TEXT_LAYOUT_CHAINED_COMPARISON_PATCHES = {
      'position = fabs(left - point.y) < fabs(right - point.y) < (right ? prev : next);' =>
        'position = (fabs(left - point.y) < fabs(right - point.y)) ? prev : next;',
      'position = fabs(left - point.x) < fabs(right - point.x) < (right ? prev : next);' =>
        'position = (fabs(left - point.x) < fabs(right - point.x)) ? prev : next;'
    }.freeze
    AFNETWORKING_NETINET6_HEADER_RELATIVE_PATHS = [
      File.join('AFNetworking', 'AFNetworking', 'AFHTTPSessionManager.m'),
      File.join('AFNetworking', 'AFNetworking', 'AFNetworkReachabilityManager.m')
    ].freeze

    def reresolve_for_texture_if_needed(analyzer)
      return analyzer if ENV['NO_TEXTURE_PATCH'] == '1'
      return analyzer if texture_user_pinned?
      return analyzer if @sandbox.development_pods.key?('Texture')

      # 收集每个 target 实际用到的、未修复的 Texture subspec
      inject_map = {}
      analysis_result.specs_by_target.each do |td, specs|
        tex = specs.select { |s| s.root.name == 'Texture' }
        next if tex.empty?
        next if tex.all? { |s| texture_spec_fixed?(s) }
        inject_map[td] = tex.map(&:name).uniq # 如 ["Texture/Core"]
      end
      return analyzer if inject_map.empty?

      target = baitu_specs_available? ? TEXTURE_FORK_SOURCE : TEXTURE_OFFICIAL_SOURCE
      ext = { git: target[:git], tag: target[:tag] }

      inject_map.each do |td, names|
        ih = td.instance_variable_get(:@internal_hash)
        deps = (ih['dependencies'] || []).dup
        # 去掉原有的同名 Texture(子)依赖，避免与外部源版本冲突
        deps.reject! { |d| names.include?(texture_dep_name(d)) }
        names.each { |n| deps << { n => [ext.dup] } }
        ih['dependencies'] = deps
        td.instance_variable_set(:@internal_hash, ih)
      end

      all_names = inject_map.values.flatten.uniq.sort
      puts "[cocoapods-publish] Texture 含主线程自锁缺陷，已为 #{all_names.join(', ')} 注入外部源 → #{target[:git]} @ #{target[:tag]}，重新解析依赖（避免测试卡死）".yellow

      # 用改过的 @podfile 重新解析：外部源进入依赖图并触发重下
      origin_resolve_dependencies
    rescue StandardError => e
      puts "[cocoapods-publish] Texture 外部源注入失败，保持原解析：#{e.message}".red
      analyzer
    end

    # Xcode 26 将 Objective-C 链式比较 `X < Y < Z` 视为硬错误。
    # YYKit/YYText/Texture 的 text layout 源码中本意是按距离选择 prev/next，需显式改成三元表达式。
    def patch_text_layout_chained_comparison
      TEXT_LAYOUT_CHAINED_COMPARISON_RELATIVE_PATHS.each do |relative_path|
        file = File.join(@sandbox.root.to_s, relative_path)
        next unless File.file?(file)

        content = File.read(file)
        patched = TEXT_LAYOUT_CHAINED_COMPARISON_PATCHES.reduce(content) do |memo, (from, to)|
          memo.gsub(from, to)
        end
        next if patched == content

        File.chmod(0o644, file) unless File.writable?(file)
        File.write(file, patched)
        fixed_count = content.scan(/position = fabs\(left - point\.[xy]\) < fabs\(right - point\.[xy]\) < \(right \? prev : next\);/).size
        puts "[cocoapods-publish] 已修复 #{relative_path} 的 text layout 链式比较（#{fixed_count} 处），兼容 Xcode 26".green
      end
    rescue StandardError => e
      puts "[cocoapods-publish] text layout 链式比较修复失败，继续安装：#{e.message}".yellow
    end

    # Xcode 26 模块校验禁止从模块外直接导入 netinet6/in6.h。
    # AFNetworking 已导入公开的 netinet/in.h，IPv6 sockaddr 声明由该公开头提供。
    def patch_afnetworking_private_netinet6_header
      AFNETWORKING_NETINET6_HEADER_RELATIVE_PATHS.each do |relative_path|
        file = File.join(@sandbox.root.to_s, relative_path)
        next unless File.file?(file)

        content = File.read(file)
        patched = content.gsub(/^\s*#import\s+<netinet6\/in6\.h>\s*\n/, '')
        next if patched == content

        File.chmod(0o644, file) unless File.writable?(file)
        File.write(file, patched)
        puts "[cocoapods-publish] 已移除 #{relative_path} 的私有头 <netinet6/in6.h>，兼容 Xcode 26".green
      end
    rescue StandardError => e
      puts "[cocoapods-publish] AFNetworking 私有头修复失败，继续安装：#{e.message}".yellow
    end

    # 依赖条目可能是 "Name" 字符串或 {"Name" => [requirements...]} 哈希
    def texture_dep_name(dep)
      dep.is_a?(Hash) ? dep.keys.first : dep
    end

    def texture_dep?(dep)
      texture_dep_name(dep).to_s.split('/').first == 'Texture'
    end

    # 解析出的 Texture spec 是否已含修复（版本 >=3.2.0 或带 BAITU 标记）
    def texture_spec_fixed?(spec)
      v = spec.version.to_s
      return true if v.include?('BAITU')
      Pod::Version.new(v[/\d+(\.\d+)*/].to_s) >= Pod::Version.new(TEXTURE_VERSION_FIXED)
    rescue StandardError
      false
    end

    # 用户是否已在 Podfile 显式 pin Texture（外部源 / 含 BAITU），是则不覆盖
    def texture_user_pinned?
      @podfile.target_definitions.any? do |_label, td|
        next false if td.nil?
        ih = td.instance_variable_get(:@internal_hash)
        deps = ih && ih['dependencies']
        next false unless deps.is_a?(Array)
        deps.any? do |d|
          next false unless texture_dep?(d)
          reqs = d.is_a?(Hash) ? d.values.first : nil
          reqs.is_a?(Array) && reqs.any? { |r| r.is_a?(Hash) || r.to_s.include?('BAITU') }
        end
      end
    rescue StandardError
      false
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
