# frozen_string_literal: true

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
          %w[--publish-framework 指定发布framework.]
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
        super
      end

      def validate!
        super
        help! '需要指定发布的组件.' unless @spec
        help! '需要指定发布组件的source.' unless @source
      end

      def run
        if @publish_framework
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
          Process.exit
        end
        UI.puts "-> #{@name} 验证通过！".green
      end

      # 增加版本号
      def increase_version_number
        @old_version = @spec.attributes_hash['version']
        @new_version = increase_number(@old_version)
        @spec.attributes_hash['version'] = @new_version
      end

      # 自增版本号
      def increase_number(number)
        numbers = number.split('.')
        count = numbers.length
        case count
        when 1 then (number.to_i + 1).to_s
        else (numbers.join('').to_i + 1).to_s.split('').join('.')
        end
      end

      # 保存新版本
      def save_new_version_to_podspec
        text = File.read(@name)
        text.gsub!("s.version          = '#{@old_version}'", "s.version          = '#{@new_version}'")
        File.open(@name, 'w') { |file| file.puts text }
      end

      # 恢复旧版本
      def restore_old_version_to_podspec
        text = File.read(@name)
        text.gsub!("s.version          = '#{@new_version}'", "s.version          = '#{@old_version}'")
        File.open(@name, 'w') { |file| file.puts text }
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
        UI.puts '-> 创建新版本...'.yellow

        command = "cd #{@project_path}"
        command += ' && git add .'
        command += " && git commit -m \"[Update] (#{@new_version})\""
        command += " && git tag -a #{@new_version} -m \"[Update] (#{@new_version})\""
        command += ' && git push origin main --tags --quiet'

        config.silent = true
        output = `#{command}`.lines
        UI.puts
        config.silent = false
        if $?.exitstatus != 0
          UI.puts "-> #{output}".red
          UI.puts "-> 创建新版本失败！Command： #{command}".red
          restore_old_version_to_podspec
          Process.exit
        end
        UI.puts "-> 新版本(#{@new_version})创建成功！".green
      end

      # 推送新版本到私有库
      def push_pods
        UI.puts "-> 发布新版本(#{@new_version})...".yellow
        config.silent = true
        argv = CLAide::ARGV.coerce([@source, @name, '--allow-warnings', "--sources=#{@sources.join(',')}"])
        begin
          command = Repo::Push::PushWithoutValid.new(argv)
          command.run
          command = Repo::Update.new(CLAide::ARGV.coerce([@source]))
          command.run
          config.silent = false
          UI.puts "-> (#{@new_version})发布成功！".green
          config.silent = true
        rescue StandardError => e
          restore_old_version_to_podspec
          config.silent = false
          UI.puts "-> #{e}".red
          UI.puts "-> (#{@new_version})发布失败！".red
          Process.exit
        end
      end

      def push_framework_pod
        version = @spec.attributes_hash['version']
        UI.puts "-> 正在发布新版本(#{version})...".yellow
        config.silent = true
        argv = CLAide::ARGV.coerce([@source, @name, '--allow-warnings', "--sources=#{@sources.join(',')}"])
        begin
          command = Repo::Push::PushWithoutValid.new(argv)
          command.run
          command = Repo::Update.new(CLAide::ARGV.coerce([@source]))
          command.run
          config.silent = false
          UI.puts "-> (#{version})发布成功！".green
          config.silent = true
        rescue StandardError
          config.silent = false
          UI.puts "-> (#{version})发布失败！".red
          Process.exit
        end
      end
    end
  end
end
