module Pod
  class Resolver

    # Hook the original `find_cached_set` method.
    alias origin_find_cached_set find_cached_set

    SWIFT_VERSION = Open3.popen3('swift --version')[1].gets.to_s.gsub(/version (\d+\.\d+?)/).to_a[0].split(' ')[1]

    # Load and return the dependencies set of the given Pod.
    def find_cached_set(dependency)
      if dependency.name.start_with?('BT') &&
         dependency.external_source.nil? &&
         !dependency.prerelease? &&
         !dependency.name.include?('/') &&
         swift_version_support?

        # 获取当前的版本号
        version = dependency.requirement.requirements[0][1].to_s

        # 已自动指定版本号
        version = modified_frameworks[dependency.name] if modified_frameworks.keys.include?(dependency.name)

        # 未指定版本号
        version = local_framework_version(dependency.name) if version == '0'

        # 判断是否已指定Swift版本号
        version = "#{version}.swift-#{SWIFT_VERSION}" unless version.include?('.swift')

        # 存储自动指定的版本号
        modified_frameworks[dependency.name] = version unless modified_frameworks.keys.include?(dependency.name)

        # 重新指定版本
        dependency.requirement.requirements[0] = ['=', Pod::Version.new(version)]
      end
      origin_find_cached_set(dependency)
    end

    def modified_frameworks
      @modified_frameworks ||= {}
    end

    def swift_framework?(repo, fw)
      # 获取文件夹列表
      folder_paths = Dir.glob("#{repo}/#{fw}/**/#{fw}.podspec").select { |entry| File.file?(entry) }

      # 使用File.mtime获取每个文件夹的修改日期并进行排序
      spec_file = folder_paths.min_by { |folder| -File.mtime(folder).to_i }
      return false if spec_file.nil?

      content = File.open(spec_file).read.to_s
      !content.gsub(/source_files =.*.swift/).to_a.empty?
    end

    def local_framework_version(fw)
      repo = "#{@sources_manager.repos_dir}/BaiTuFrameworkPods"
      # 获取文件夹列表
      folder_paths = Dir.glob("#{repo}/#{fw}/**/#{fw}.podspec").select { |entry| File.file?(entry) }

      # 使用File.mtime获取每个文件夹的修改日期并进行排序
      spec_file = folder_paths.min_by { |folder| -File.mtime(folder).to_i }
      return '0' if spec_file.nil?

      spec = Specification.from_file(spec_file)
      spec.attributes_hash['version']
    end

    def local_swift_version
      _, stdout, _ = Open3.popen3('swift --version')
      stdout.gets.to_s.gsub(/version (\d+\.\d+?)/).to_a[0].split(' ')[1]
    end

    def swift_version_support?
      SWIFT_VERSION.gsub(/\d+\.\d+/).to_a[0].gsub('.', '').to_i >= 59
    end

  end
end
