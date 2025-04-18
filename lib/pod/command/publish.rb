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
          %w[--beta 发布beta版本],
          %w[--upgrade-swift 升级Swift版本],
          %w[--subspecs 同时构建的subspec],
          %w[--mixup-publish 混淆]
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

        # 构建子subspec支持
        subspecs = argv.option('subspecs')
        @subspecs = subspecs.split(',') unless subspecs.nil?

        # 发布beta版本
        @beta_version_publish = argv.flag?('beta', false)

        # 升级Swift版本
        @upgrade_swift_publish = argv.flag?('upgrade-swift', false)

        @swift_version = local_swift_version

        # 发布到GitHub源码
        @to_github = argv.flag?('to-github', false)

        # 是否混淆
        @mixup_publish = argv.flag?('mixup-publish', false)

        super
      end

      def validate!
        super
        help! '需要指定发布的组件.' unless @spec
        help! '需要指定发布组件的source.' unless @source
      end

      def run

        @scheme_map = {
          'PLA' => 'poppo',
          'VO' => 'vone',
          'MNL' => 'mimi',
          'MTI' => 'miti',
          'MIU' => 'miu',
          'ZSL' => 'jolly',
          'PPL' => 'poppolite'
        }

        if @to_github
          push_pod_to_github
          return
        end

        @current_branch = get_current_branch.upcase
        @pod_name = @spec.attributes_hash['name']

        @is_version_need_attach_branch = @pod_name == 'BTAssets' && @current_branch != 'MAIN'

        if @publish_framework
          increase_version_number
          save_new_version_to_podspec
          update_zip_file_for_version(@new_version, nil)
          push_framework_pod

          # 发布subspec特定版本
          unless @subspecs.nil?
            if @subspecs.count > 0
              @main_version = @new_version
              @main_old_version = @old_version
              @subspecs.each do |subspec|
                @old_version = @new_version
                @new_version = version_for_subspec(subspec)
                save_new_version_to_podspec
                # 混淆不改podspec文件
                save_new_default_subspec(subspec) unless @mixup_publish
                update_zip_file_for_version(@new_version, subspec)
                push_framework_pod
                restore_old_version_to_podspec
                # 混淆不改podspec文件
                restore_default_subspec(subspec) unless @mixup_publish
                restore_zip_file_for_version(@main_version)

                @old_version = @main_old_version
                @new_version = @main_version
              end
            end
          end

          if @pod_name == 'BTRouter' && !@beta_version_publish
            # 只发正式版
            old_version = @new_version
            @scheme_map.each do |_key, val|
              @new_version = "#{old_version}.#{val.upcase}"
              save_new_version_to_podspec
              update_zip_file_for_version(@new_version, nil)
              push_framework_pod
              @old_version = @new_version
              restore_old_version_to_podspec
            end

            @old_version = old_version
            restore_old_version_to_podspec

          end

          # 处理Swift版本信息
          old_ver = @old_version
          if @new_version.include?('.swift')
            @old_version = @new_version.split('.swift')[0]
            restore_old_version_to_podspec
          end

          # restore_old_version_to_podspec if @is_version_need_attach_branch
          if @pod_name == 'BTAssets'
            branch = get_current_branch

            command = "git add . && git commit -m \"[Update] (#{@old_version})\""
            command += " && git push origin #{branch} --quiet"

            config.silent = true
            output = `#{command}`.lines
            UI.puts
            config.silent = false

            if $?.exitstatus != 0
              UI.puts "-> #{output}".red
              UI.puts "-> 代码提交失败！Command： #{command}".red
              restore_old_version_to_podspec
            end
          end

          if @beta_version_publish
            @new_version = @new_version.split('.swift')[0] if @new_version.include?('.swift')

            branch = get_current_branch

            command = "git add . && git commit -m \"[Beta] (#{@new_version})\""
            command += " && git push origin #{branch} --quiet"

            config.silent = true
            output = `#{command}`.lines
            UI.puts
            config.silent = false

            if $?.exitstatus != 0
              UI.puts "-> #{output}".red
              UI.puts "-> 代码提交失败！Command： #{command}".red
              @old_version = old_ver
              restore_old_version_to_podspec
            end
          end
          `git restore .`
          return
        end
        @project_path = Pathname(@name).parent.to_s
        validate_podspec unless @skip_lib_lint
        check_remote_repo
        increase_version_number
        save_new_version_to_podspec
        check_repo_status
        push_pods
        `git restore .`
      end

      def version_for_subspec(subspec)
        version = @main_version
        version = @main_version.gsub('.swift-', ".#{subspec}.swift-") if version.include?('.swift-')
        if version.include?(".#{@current_branch}")
          version = @main_version.gsub(".#{@current_branch}", ".#{subspec}.#{@current_branch}")
        end
        version = "#{version}.#{subspec}" if !version.include?(".#{@current_branch}") && !version.include?('.swift-')
        version
      end

      def update_zip_file_for_version(version, subspec)
        zip_file_path = get_zip_path(version, subspec)
        modify_zip_path(zip_file_path)
      end

      def get_zip_path(version, subspec)
        zip_file_path = "repository/files/#{version}"
        if version.include?('.b')
          zip_file_path = "repository/files/#{version.split('.b')[0]}-beta"
        elsif version.include?('.swift')
          zip_file_path = "repository/files/#{version.split('.swift')[0]}"
        end
        zip_file_path = zip_file_path.gsub(".#{subspec}", '') if !subspec.nil? && zip_file_path.include?(".#{subspec}")

        if @pod_name == 'BTRouter'
          @scheme_map.each_value do |val|
            zip_file_path = zip_file_path.gsub(".#{val.upcase}", '') if zip_file_path.include?(".#{val.upcase}")
          end
        end
        zip_file_path
      end

      def restore_zip_file_for_version(version)
        zip_file_path = "repository/files/\#{s.version}"
        modify_zip_path(zip_file_path)
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

      # require 'Open3'
      def local_swift_version
        _, stdout, _ = Open3.popen3('xcrun swift --version')
        stdout.gets.to_s.gsub(/version (\d+(\.\d+)+)/).to_a[0].split(' ')[1]
      end

      FW_EXCLUDE_NAMES = %w[BTDContext].freeze
      def swift_version_support?
        name = @spec.attributes_hash['name']
        # 过滤白名单
        return false unless FW_EXCLUDE_NAMES.filter { |nm| name.include?(nm) }.empty?

        content = File.open(@name).read.to_s
        @swift_version.gsub(/\d+\.\d+/).to_a[0].gsub('.', '').to_i >= 59 && !content.gsub(/source_files.*=.*.swift/).to_a.empty?
      end

      # 增加版本号
      def increase_version_number
        @old_version = @spec.attributes_hash['version']
        version = @old_version
        version = version.split('.swift')[0] if version.include?('.swift')
        version = version.split(".#{@current_branch}")[0] if version.include?(".#{@current_branch}")
        @new_version = version

        @new_version = increase_number(version) unless @publish_framework
        @new_version = increase_number(version) if @pod_name == 'BTAssets'
        @new_version = "#{@new_version}.#{@current_branch}" if @is_version_need_attach_branch

        # TODO: 适配仅源码模式
        if @publish_framework
          if @upgrade_swift_publish && swift_version_support?
            @new_version = version
          else
            if @beta_version_publish
              # 自增版本号
              @new_version = increase_number(version)
            end
          end
          # 处理Swift版本
          @new_version = "#{@new_version}.swift-#{@swift_version}" if swift_version_support?
        end
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

      def save_new_default_subspec(subspec)
        content = File.read(@name)
        old_subspec = 'Core_Framework'
        old_subspec = 'CoreFramework' unless content.include?("s.subspec 'Core_Framework'")
        # 替换组件default_subspec
        content = content.gsub(/s.subspec '#{old_subspec}'/, "s.subspec '#{old_subspec}_1'")
        content = content.gsub(/s.subspec '#{subspec}_Framework'/, "s.subspec '#{old_subspec}'")
        File.open(@name, 'w') { |file| file.puts content }
      end

      def restore_default_subspec(subspec)
        content = File.read(@name)
        old_subspec = 'Core_Framework'
        old_subspec = 'CoreFramework' unless content.include?("s.subspec 'Core_Framework'")
        # 替换组件default_subspec
        content = content.gsub(/s.subspec '#{old_subspec}'/, "s.subspec '#{subspec}_Framework'")
        content = content.gsub(/s.subspec '#{old_subspec}_1'/, "s.subspec '#{old_subspec}'")
        File.open(@name, 'w') { |file| file.puts content }
      end

      # 修改zip下载path
      def modify_zip_path(to)
        content = File.open(@name).read

        # 找到匹配的第一行位置
        match_line_index = nil
        content_lines = content.lines
        content_lines.each_with_index do |line, index|
          if line.include?('zip_file_path =')
            match_line_index = index
            break
          end
        end

        # 删除包含 zip_file_path = 的所有行
        content_lines.reject! { |line| line.include?('zip_file_path =') }

        # 在匹配的第一行位置插入新内容
        if match_line_index
          content_lines.insert(match_line_index, "  zip_file_path = \"#{to}\"\n")
        end

        # 重新组合内容
        content = content_lines.join
        File.open(@name, 'w') { |file| file.puts content }
      end

      # 适配新的文件保存路径
      def check_pod_http_source_publish
        content = File.open(@name).read.to_s
        # 已添加subspec跳过
        return if content.include?('zip_file_path = ')

        zip_file_path = get_zip_path(@new_version, nil)

        zip_file_path = <<~CONTENT
          zip_file_path = "#{zip_file_path}"
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

      def push_sources
        UI.puts '-> 推送代码...'.yellow unless @from_wukong
        branch = get_current_branch

        command = "cd #{@project_path}"
        command += ' && git add .'
        command += " && git commit -m \"[Update] (#{@new_version})\""
        command += " && git push origin #{branch} --quiet"

        config.silent = true
        output = `#{command}`.lines
        UI.puts
        config.silent = false
        if $?.exitstatus != 0
          UI.puts "-> #{output}".red
          UI.puts "-> 代码推送失败！Command： #{command}".red
          restore_old_version_to_podspec
          Process.exit(1)
        end

        UI.puts '-> 推送代码成功！'.green unless @from_wukong
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
          command = Repo::Update.new(CLAide::ARGV.coerce([@source]))
          command.run
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
        rescue StandardError => e
          restore_old_version_to_podspec if @beta_version_publish
          config.silent = false
          UI.puts "-> (#{version})发布失败：#{e.message}".red
          Process.exit(1)
        end
      end

      def push_pod_to_github
        version = @spec.attributes_hash['version']
        UI.puts "-> 正在发布新版本(#{version})...".yellow unless @from_wukong
        config.silent = true
        argv = CLAide::ARGV.coerce([@source, @name, '--allow-warnings', '--sources=trunk'])
        begin
          command = Repo::Push::PushWithoutValid.new(argv)
          command.run
          command = Repo::Update.new(CLAide::ARGV.coerce([@source]))
          command.run
          config.silent = false
          UI.puts "-> (#{version})发布成功！".green unless @from_wukong
          config.silent = true
        rescue StandardError => e
          restore_old_version_to_podspec if @beta_version_publish
          config.silent = false
          UI.puts "-> (#{version})发布失败：#{e.message}".red
          Process.exit(1)
        end
      end
    end
  end
end