# frozen_string_literal: true

require 'English'
require 'pod/command/auto'

module Pod
  class Command
    class Publish < Command
      self.summary = '自动发布组件到私有组件仓库.'

      self.arguments = [
        CLAide::Argument.new('NAME', true)
      ]

      def self.options
        [
          %w[--swift-version 指定Swift版本.],
          %w[--skip-import-validation 跳过import_validation验证.],
          %w[--skip-lib-lint 跳过lib验证.],
          %w[--sources 指定依赖的组件仓库.],
          %w[--publish-framework 指定发布framework.],
          %w[--from-wukong 发起者为`wukong`],
          %w[--beta 发布beta版本]
        ]
      end

      def initialize(argv)
        @source = argv.shift_argument
        @name = argv.shift_argument
        @swift_version = argv.option('swift-version', nil)
        @skip_import_validation = argv.flag?('skip-import-validation', false)
        @skip_lib_lint = argv.flag?('skip-lib-lint', false)
        @sources = argv.option('sources', 'trunk,BaiTuPods,BaiTuFrameworkPods').split(',')
        @spec = spec_with_path(@name)
        @publish_framework = argv.flag?('publish-framework', false) || @source.eql?('BaiTuFrameworkPods')
        @from_wukong = argv.flag?('from-wukong', false)

        # 发布beta版本
        @beta_version_publish = argv.flag?('beta', false)

        super
      end

      def validate!
        super
        help! '需要指定发布的组件.' unless @spec
        help! '需要指定发布组件的source.' unless @source
      end

      def run

        if @publish_framework
          if @beta_version_publish
            increase_version_number
            save_new_version_to_podspec
          end
          push_framework_pod
          return
        end
        @project_path = Pathname(@name).parent.to_s
        validate_podspec unless @skip_lib_lint
        check_remote_repo
        increase_version_number
        save_new_version_to_podspec
        check_repo_status
        push_pods
      end

      # 验证.podspec 执行 pod lib lint xxx.podspec
      def validate_podspec
        UI.puts "-> 验证#{@name}...".yellow
        config.silent = true
        validator = Validator.new(@spec, @sources)
        validator.local = true
        validator.no_clean = false
        validator.allow_warnings = true
        validator.use_frameworks = true
        # validator.use_modular_headers = true if validator.respond_to?(:use_modular_headers=)
        validator.swift_version = @swift_version if validator.respond_to?(:swift_version=)
        validator.skip_import_validation = @skip_import_validation
        validator.skip_tests = true
        validator.validate

        config.silent = false
        unless validator.validated?
          UI.puts "-> #{@name} 验证未通过！Command：pod lib lint #{@name} --use-libraries --allow-warnings --sources=#{@sources.join(',')}".red
          Process.exit(1)
        end
        UI.puts "-> #{@name} 验证通过！".green
      end

      SWIFT_VERSION = `swift --version`.to_s.gsub(/version (\d+\.\d+(\.\d+)?)/).to_a[0].split(' ')[1].freeze

      def swift_version_support?
        SWIFT_VERSION.gsub(/\d+\.\d+/).to_a[0].gsub('.', '').to_i >= 59
      end

      def version_valid?(version)
        `git tag`.to_s.split("\n").include?(version)
      end

      # 增加版本号
      def increase_version_number
        @old_version = @spec.attributes_hash['version']
        @new_version = @old_version
        unless version_valid?(@new_version)
          # 处理Swift版本
          swift_version = @new_version
          swift_version = "#{@new_version}.swift-#{SWIFT_VERSION}" if swift_version_support?
          @new_version = increase_number(@new_version) unless version_valid?(swift_version)
        end

        # 处理Swift版本
        @new_version = "#{@new_version}.swift-#{SWIFT_VERSION}" if swift_version_support?

        @spec.attributes_hash['version'] = @new_version
      end

      # 自增版本号
      def increase_number(number)
        if @beta_version_publish
          new_version = "#{number}.b1"
          if number.include?('.b')
            v = number.split('.b')[0]
            b_v = number.split('.b')[1].to_i
            b_v += 1
            new_version = "#{v}.b#{b_v}"
          end
          return new_version
        end

        number = number.split('.b')[0] if number.include?('.b')

        numbers = number.split('.')
        count = numbers.length
        case count
        when 1 then (number.to_i + 1).to_s
        else (numbers.join('').to_i + 1).to_s.split('').join('.')
        end
      end

      def remove_swift_version
        return nil unless @new_version.include?(".swift")

        @new_version = @new_version.split('.swift')[0]
        save_new_version_to_podspec

        command = 'git add .'
        command += " && git commit -m \"[Update] (#{@new_version})\""
      end

      # 保存新版本
      def save_new_version_to_podspec
        text = File.read(@name)
        text.gsub!("s.version          = '#{@old_version}'", "s.version          = '#{@new_version}'")
        File.open(@name, 'w') { |file| file.puts text }

        check_pod_http_source_publish
      end

      # 恢复旧版本
      def restore_old_version_to_podspec
        text = File.read(@name)
        text.gsub!("s.version          = '#{@new_version}'", "s.version          = '#{@old_version}'")
        File.open(@name, 'w') { |file| file.puts text }
      end

      # 适配新的文件保存路径
      def check_pod_http_source_publish
        content = File.open(@name).read.to_s
        # 已添加subspec跳过
        return if content.include?("s.version.to_s.include?('.swift')")

        if content.include?('zip_file_path = s.')
          zip_file_path = <<~CONTENT
            zip_file_path = s.version.to_s.include?('.b') ? "repository/files/#\{s.version.to_s.split('.b')[0]}-beta" : "repository/files/#\{s.version.to_s}"
          CONTENT
          new_zip_file_path = <<~CONTENT
            zip_file_path = s.version.to_s.include?('.b') ? "repository/files/#\{s.version.to_s.split('.b')[0]}-beta" : s.version.to_s.include?('.swift') ? "repository/files/#\{s.version.to_s.split('.swift')[0]}" : "repository/files/#\{s.version.to_s}"
          CONTENT
          content.gsub!(zip_file_path, new_zip_file_path)
          File.open(@name, 'w') { |fw| fw.write(content) }
          return
        end

        zip_file_path = <<~CONTENT
          zip_file_path = s.version.to_s.include?('.b') ? "repository/files/#\{s.version.to_s.split('.b')[0]}-beta" : s.version.to_s.include?('.swift') ? "repository/files/#\{s.version.to_s.split('.swift')[0]}" : "repository/files/#\{s.version.to_s}"
            if use_framework
        CONTENT
        zip_file_path = zip_file_path.chomp
        content.gsub!(%r{repository/files/#\{s.name.to_s\}-#\{s.version.to_s\}\.zip/raw\?ref=main",}, zip_file_path)

        if content.include?("if ENV['")
          content.gsub!(/# 以下为脚本依赖CoreFramework自动生成代码，勿动⚠️⚠️ 如CoreFramework有改动请删除。[\w\W]*?\bend[\w\W]*?end/, '')
        else
          content.gsub!(/# 以下为脚本依赖CoreFramework自动生成代码，勿动⚠️⚠️ 如CoreFramework有改动请删除。[\w\W]*?\bend/, '')
        end

        zip_file_path = <<~CONTENT
          end

            s.subspec
        CONTENT
        content.gsub!(/\bend\W*?\bs.subspec/, zip_file_path.chomp)

        File.open(@name, 'w') { |fw| fw.write(content) }
      end

      # 检查当前仓库状态
      def check_repo_status
        create_tag if check_tag
      end

      def check_tag
        output = `cd #{@project_path} && git tag -l #{@new_version}`.lines.to_a
        output.empty?
      end

      # 创建tag
      def create_tag
        UI.puts '-> 创建新版本...'.yellow unless @from_wukong
        branch = get_current_branch

        command = "cd #{@project_path}"
        command += ' && git add .'
        command += " && git commit -m \"[Update] (#{@new_version})\""
        # command += ' && git fetch'
        # command += " && git pull origin #{branch}"
        command += " && git tag -a #{@new_version} -m \"[Update] (#{@new_version})\""

        # 处理Swift版本信息
        if @new_version.include?(".swift")
          @new_version = @new_version.split('.swift')[0]
          save_new_version_to_podspec

          command += '&& git add .'
          command += " && git commit -m \"[Update] (#{@new_version})\""
        end

        command += " && git push origin #{branch} --tags --quiet"

        config.silent = true
        output = `#{command}`.lines
        UI.puts
        config.silent = false
        if $?.exitstatus != 0
          UI.puts "-> #{output}".red
          UI.puts "-> 创建新版本失败！Command： #{command}".red
          restore_old_version_to_podspec
          Process.exit(1)
        end
        UI.puts "-> 新版本(#{@new_version})创建成功！".green unless @from_wukong
      end

      def get_current_branch
        `git symbolic-ref --short HEAD`.to_s.chomp
      end

      # 推送新版本到私有库
      def push_pods
        UI.puts "-> 发布新版本(#{@new_version})...".yellow unless @from_wukong
        config.silent = true
        argv = CLAide::ARGV.coerce([@source, @name, '--allow-warnings', "--sources=#{@sources.join(',')}"])
        begin
          command = Repo::Push::PushWithoutValid.new(argv)
          command.run
          command = Repo::Update.new(CLAide::ARGV.coerce([@source]))
          command.run
          config.silent = false
          UI.puts "-> (#{@new_version})发布成功！".green unless @from_wukong
          config.silent = true
        rescue StandardError => e
          restore_old_version_to_podspec
          config.silent = false
          UI.puts "-> #{e}".red
          UI.puts "-> (#{@new_version})发布失败！".red
          Process.exit(1)
        end
      end

      def push_framework_pod
        version = @spec.attributes_hash['version']
        UI.puts "-> 正在发布新版本(#{version})...".yellow unless @from_wukong
        config.silent = true
        argv = CLAide::ARGV.coerce([@source, @name, '--allow-warnings', "--sources=#{@sources.join(',')}"])
        begin
          command = Repo::Push::PushWithoutValid.new(argv)
          command.run
          command = Repo::Update.new(CLAide::ARGV.coerce([@source]))
          command.run
          config.silent = false
          UI.puts "-> (#{version})发布成功！".green unless @from_wukong
          config.silent = true
        rescue StandardError
          config.silent = false
          UI.puts "-> (#{version})发布失败！".red
          Process.exit(1)
        end
      end
    end
  end
end