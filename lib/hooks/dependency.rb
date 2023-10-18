module Pod
  class Dependency
    SWIFT_VERSION = Open3.popen3('swift --version')[1].gets.to_s.gsub(/version (\d+\.\d+?)/).to_a[0].split(' ')[1]
    alias origin_initialize initialize

    # 混淆支持
    FW_MIXUP_SUPPORT = %w[VO MNL PPL ZSL PAS].freeze

    def initialize(name = nil, *requirements)
      return origin_initialize(name, *requirements) if name.nil? || name.empty?

      if name.start_with?('BT') &&
         !requirements.last.is_a?(Hash) &&
         swift_framework?(name) &&
         swift_version_support?
        if name.include?('/')
          unless FW_MIXUP_SUPPORT.filter { |prefix| name.include?("/#{prefix}") }.empty?
            requirements = [genrate_requirements(name, requirements)]
          end
        else
          requirements = [genrate_requirements(name, requirements)]
        end
      end

      if name.start_with?('BT') &&
         !requirements.last.is_a?(Hash) &&
         swift_framework?(@name) &&
         !swift_version_support?
        requirements = [rebind_version(requirements)]
      end

      origin_initialize(name, *requirements)
    end

    def genrate_requirements(name, requirements)
      return requirements if requirements.empty?

      # puts "-> 安装依赖前：#{name}, requirements:#{requirements}"

      # 获取当前的版本号
      version = requirements[0]

      # 已自动指定版本号
      version = modified_frameworks[name] if modified_frameworks.keys.include?(name)

      # 未指定版本号
      version = local_framework_version(name) if version.is_a?(Array)

      # 判断是否已指定Swift版本号
      version = "#{version}.swift-#{SWIFT_VERSION}" unless version.include?('.swift')

      # 存储自动指定的版本号
      modified_frameworks[name] = version unless modified_frameworks.keys.include?(name)

      # puts "-> 安装依赖后：#{name}, requirements:#{version}"
      # 重新指定版本
      version
    end

    def rebind_version(requirements)
      return requirements if requirements.empty?

      version = requirements[0].to_s
      version = version.split('.swift')[0] if version.include?('.swift')
      version
    end

    def modified_frameworks
      @modified_frameworks ||= {}
    end

    FW_EXCLUDE_NAMES = %w[BTDContext BTAssets].freeze
    def swift_framework?(fw)
      return false if fw.nil?
      # 过滤白名单
      return false unless FW_EXCLUDE_NAMES.filter { |name| fw.include?(name) }.empty?

      podfile_path = Pod::Config.instance.podfile.defined_in_file.to_s
      if File.exist?(podfile_path)
        return false unless File.read(podfile_path).to_s.gsub(/pod*.'#{fw}',*.:path =>*.*:dev =>*.1/).to_a.empty?
      else
        deps = Pod::Config.instance.podfile.to_hash['target_definitions'][0]['children'][0]['dependencies']
        if deps.keys.include?(fw) && !deps[fw].empty?
          h = deps[fw][0]
          return false if h.is_a?(Hash) && !h[:path].nil? && h[:dev] == 1
        end
      end

      fw = fw.split('/')[0] if fw.include?('/')
      repo = "#{Pod::Config.instance.repos_dir}/BaiTuFrameworkPods"
      # 获取文件夹列表
      folder_paths = Dir.glob("#{repo}/#{fw}/**/#{fw}.podspec").select { |entry| File.file?(entry) }

      # 使用File.mtime获取每个文件夹的修改日期并进行排序
      # spec_file = folder_paths.max_by { |folder| `cd #{repo} && git log --reverse --pretty=format:"%ad" -- .#{folder.gsub(repo, '')} | tail -n 1` }
      spec_file = folder_paths.max_by { |folder| Pathname(folder).parent.basename }
      return false if spec_file.nil?

      content = File.open(spec_file).read.to_s
      !content.gsub(/source_files.*=.*.swift/).to_a.empty?
    end

    def local_framework_version(fw)
      repo = "#{Pod::Config.instance.repos_dir}/BaiTuFrameworkPods"
      # 获取文件夹列表
      folder_paths = Dir.glob("#{repo}/#{fw}/**/#{fw}.podspec").select { |entry| File.file?(entry) && entry != "#{repo}/#{fw}/#{fw}.podspec" }

      # 使用File.mtime获取每个文件夹的修改日期并进行排序
      spec_file = folder_paths.max_by { |folder| Pathname(folder).parent.basename }
      return [] if spec_file.nil?

      spec = Specification.from_file(spec_file)
      spec.attributes_hash['version']
    end

    def swift_version_support?
      SWIFT_VERSION.gsub(/\d+\.\d+/).to_a[0].gsub('.', '').to_i >= 59
    end

  end

end
