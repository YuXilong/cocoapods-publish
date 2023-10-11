# frozen_string_literal: true
module Pod
  class Installer
    class Analyzer
      # Caches podfile & target definition dependencies, so they do not need to be re-computed
      # from the internal hash on each access
      #
      class PodfileDependencyCache
        # XCODE_VERSION = `xcodebuild -version`.to_s.split("\n")[0].split(' ')[1].freeze

        # require 'Open3'
    #     def local_swift_version
    #       _, stdout, _ = Open3.popen3('xcrun swift --version')
    #       stdout.gets.to_s.gsub(/version (\d+\.\d+?)/).to_a[0].split(' ')[1]
    #     end
    #
    #     def initialize(podfile_dependencies, dependencies_by_target_definition)
    #       @podfile_dependencies = podfile_dependencies
    #       @dependencies_by_target_definition = dependencies_by_target_definition
    #       return
    #       return if ENV['USE_FRAMEWORK'] != '1'
    #
    #       @swift_version = local_swift_version
    #       return unless swift_version_support?
    #
    #       # 处理Swift版本
    #       deps = @podfile_dependencies.filter do |dep|
    #         dep.name.start_with?('BT') && dep.external_source.nil?
    #       end
    #
    #       deps = deps.filter do |dep|
    #         version = dep.requirement.requirements[0][1].to_s
    #         version.gsub('.swift').count.zero?
    #       end
    #
    #       repo = Pod::Config.instance.sources_manager.instance_variable_get(:@sources_by_path)
    #                         .filter { |_, v| v.to_s.eql?('BaiTuFrameworkPods') }
    #                         .map { |k, _| k }[0]
    #                         .to_s
    #       deps = deps.filter do |dep|
    #         swift_framework?(repo, dep.name)
    #       end
    #
    #       # 指定Swift版本号
    #       deps.each do |dep|
    #         version = dep.requirement.requirements[0][1].to_s
    #         if version.eql?("0")
    #           # 未指定版本号
    #           version = lastest_version(repo, dep.name)
    #         end
    #
    #         dep.requirement.requirements[0][0] = '=' if dep.requirement.requirements[0][0] != '='
    #
    #         version = "#{version}.swift-#{@swift_version}" unless version.include?('.swift')
    #         dep.requirement.requirements[0][1] = Pod::Version.new(version)
    #       end
    #     end
    #
    #     def swift_framework?(repo, fw)
    #       # 获取文件夹列表
    #       folder_paths = Dir.glob("#{repo}/#{fw}/**/#{fw}.podspec").select { |entry| File.file?(entry) }
    #
    #       # 使用File.mtime获取每个文件夹的修改日期并进行排序
    #       spec_file = folder_paths.min_by { |folder| -File.mtime(folder).to_i }
    #       return false if spec_file.nil?
    #
    #       content = File.open(spec_file).read.to_s
    #       !content.gsub(/source_files =.*\.swift'/).to_a.empty?
    #     end
    #
    #     def lastest_version(repo, fw)
    #       # 获取文件夹列表
    #       folder_paths = Dir.glob("#{repo}/#{fw}/**/#{fw}.podspec").select { |entry| File.file?(entry) }
    #
    #       # 使用File.mtime获取每个文件夹的修改日期并进行排序
    #       spec_file = folder_paths.min_by { |folder| -File.mtime(folder).to_i }
    #       return "0" if spec_file.nil?
    #       spec = Specification.from_file(spec_file)
    #       spec.attributes_hash['version']
    #     end
    #
    #     def swift_version_support?
    #       @swift_version.gsub(/\d+\.\d+/).to_a[0].gsub('.', '').to_i >= 59
    #     end
      end
    end
  end
end
