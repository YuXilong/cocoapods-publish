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
          %w[--mixup-publish 混淆],
          %w[--new-class-prefixes 混淆时要修改的目标类前缀，多个用,隔开.默认为：`MNL,PPL`],
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
        @subspecs = if subspecs.nil?
                      []
                    else
                      subspecs.split(',')
                    end

        # 发布beta版本
        @beta_version_publish = argv.flag?('beta', false)

        # 升级Swift版本
        @upgrade_swift_publish = argv.flag?('upgrade-swift', false)

        @swift_version = local_swift_version

        # 发布到GitHub源码
        @to_github = argv.flag?('to-github', false)

        # 是否混淆
        @mixup_publish = argv.flag?('mixup-publish', false)

        # 类混淆
        new_class_prefixes = argv.option('new-class-prefixes')
        @new_class_prefixes = if new_class_prefixes.nil?
                                []
                              else
                                new_class_prefixes.split(',')
                              end

        # 函数混淆标志位
        mixup_func_class_prefixes = argv.option('mixup-func-class-prefixes')
        @mixup_func_class_prefixes = if mixup_func_class_prefixes.nil?
                                       []
                                     else
                                       mixup_func_class_prefixes.split(',')
                                     end

        # 不自增版本号
        @increase_version = argv.flag?('increase-version', true)
        super
      end

      def validate!
        super
        help! '需要指定发布的组件.' unless @spec
        help! '需要指定发布组件的source.' unless @source
      end

      def run
        if @to_github
          push_pod_to_github
          return
        end

        @scheme_map = {
          'PLA' => 'poppo',
          'VO' => 'vone',
          'MNL' => 'mimi',
          'MTI' => 'miti',
          'MIU' => 'miu',
          'ZSL' => 'jolly',
          'PPL' => 'poppolite'
        }
        @current_branch = get_current_branch.upcase
        @pod_name = @spec.attributes_hash['name']

        @is_version_need_attach_branch = @pod_name == 'BTAssets' && @current_branch != 'MAIN'

        # 创建工作目录
        create_work_dir

        # 解析版本号
        @new_version = generate_new_version

        if @publish_framework
          case @pod_name
          when 'BTAssets'
            @new_spec_name = @pod_name
            save_new_version_to_podspec
            update_zip_file_for_version(@new_version)
            push_framework_pod
          when 'BTRouter'
            @new_spec_name = @pod_name
            save_new_version_to_podspec
            update_zip_file_for_version(@new_version)
            push_framework_pod
            unless @beta_version_publish
              # 只发正式版
              old_version = @new_version
              @scheme_map.each do |_key, val|
                @new_version = append_version_meta(old_version, val.upcase)
                save_new_version_to_podspec
                update_zip_file_for_version(@new_version)
                push_framework_pod
              end
            end
          else
            push_mixup_pods
          end

          clean
          save_new_version_to_local_podspec
          push_code
          return
        end
        @project_path = Pathname(@name).parent.to_s
        validate_podspec unless @skip_lib_lint
        check_remote_repo
        save_new_version_to_local_podspec
        check_repo_status
        push_pods
      end

      private

      def code_version
        version = @version_number.to_s
        version = "#{@version_number}.b#{@beta_version_number}" if @beta_version_publish
        version
      end

      def push_code
        # 本地仓库无修改
        return unless git_dirty?
        version = code_version
        branch = get_current_branch

        command = "git add . && git commit -m \"[Update] (#{version})\""
        command += " && git push origin #{branch} --quiet"

        config.silent = true
        output = `#{command}`.lines
        UI.puts
        config.silent = false

        if $?.exitstatus != 0
          UI.puts "-> 代码提交失败！Command： #{command}".red
          `git reset --hard HEAD~1`
        end
      end

      def git_dirty?
        status = `git status --porcelain`
        !status.strip.empty?
      end


      def push_mixup_pods
        unless @beta_version_publish
          # 发布主版本
          @new_spec_name = @pod_name
          save_new_version_to_podspec
          update_zip_file_for_version(@new_version)
          push_framework_pod
        end

        return if @new_class_prefixes.count.zero? && @subspecs.count.zero?

        # 带有混淆
        version = @new_version
        @new_class_prefixes.each do |cls|
          @new_spec_name = if cls.split('=>').count > 1
                             cls.split('=>')[1]
                           else
                             @pod_name.gsub('BT', cls)
                           end
          cls = cls.split('=>')[0]
          meta = if @subspecs.include?(cls) && @mixup_func_class_prefixes.include?(cls)
                   @subspecs.delete(cls)
                   @mixup_func_class_prefixes.delete(cls)
                   "#{cls}-SCF"
                 elsif @mixup_func_class_prefixes.include?(cls)
                   @mixup_func_class_prefixes.delete(cls)
                   "#{cls}-CF"
                 elsif @subspecs.include?(cls)
                   @subspecs.delete(cls)
                   "#{cls}-SC"
                 else
                   "#{cls}-C"
                 end
          @new_version = append_version_meta(version, meta)
          save_new_version_to_podspec
          save_new_default_subspec(cls)
          update_zip_file_for_version(@new_version)
          push_framework_pod
        end

        @subspecs.each do |cls|
          @new_spec_name = @pod_name
          @new_spec_name.gsub!('BT', cls) unless @pod_name.include?('BTBytedEffect')
          meta = "#{cls}-S"
          @new_version = append_version_meta(version, meta)
          save_new_version_to_podspec
          save_new_default_subspec(cls)
          update_zip_file_for_version(@new_version)
          push_framework_pod
        end
      end

      def update_zip_file_for_version(version)
        zip_file_path = if version.include?('.b')
                          "repository/files/#{version.split('.b')[0]}-beta"
                        else
                          "repository/files/#{version.split('.')[0]}"
                        end
        modify_zip_path(zip_file_path)
      end

      def create_work_dir
        @work_dir = "#{Dir.pwd}/.pods/"
        FileUtils.rm_rf(@work_dir) if Pathname(@work_dir).exist?
        FileUtils.mkdir(@work_dir)
        @push_podspec_file = "#{@work_dir}/#{@spec.name}.podspec"
      end

      def clean
        FileUtils.rm_rf(@work_dir) if Pathname(@work_dir).exist?
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

      def parse_version
        version = @spec.attributes_hash['version']
        @old_version = version

        @version_number = version[/^\d+(?:\.\d+){0,3}/].gsub('.', '').to_i
        @beta_version_number = if version.include?('.b')
                                 version[/\b(b\d+)\b/, 1].gsub('b', '').to_i
                               else
                                 0
                               end
      end

      def append_version_meta(version, append_meta)
        return version.gsub('.swift', ".#{append_meta}.swift") if version.include?('.swift')

        "#{version}.#{append_meta}"
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

      # 增加版本号
      def generate_new_version
        # 版本号自增
        parse_version
        increase_number if @increase_version
        new_version = @version_number.to_s
        if @is_version_need_attach_branch
          # 附带分支名称的不发beta
          new_version = "#{@version_number}.#{@current_branch}"
          # 处理Swift版本
          return "#{new_version}.swift-#{@swift_version}" if swift_version_support?

          return new_version
        end

        if @upgrade_swift_publish && swift_version_support?
          # swift 版本升级
          version = @spec.attributes_hash['version']
          new_version = version.split('.swift')[0] if version.include?('.swift')
          # 处理Swift版本
          return "#{new_version}.swift-#{@swift_version}" if swift_version_support?

          return new_version
        end

        if @beta_version_publish
          # beta版本
          new_version = "#{@version_number}.b#{@beta_version_number}"
          # 处理Swift版本
          return "#{new_version}.swift-#{@swift_version}" if swift_version_support?

          return new_version
        end

        # 处理Swift版本
        "#{new_version}.swift-#{@swift_version}" if swift_version_support?
        new_version
      end

      # 自增版本号
      def increase_number
        if @beta_version_publish
          @beta_version_number += 1
          return
        end
        @version_number += 1
      end

      # 保存新版本
      def save_new_version_to_podspec
        text = File.read(@name)
        text.gsub!("s.version          = '#{@old_version}'", "s.version          = '#{@new_version}'")
        File.open(@push_podspec_file, 'w') { |file| file.puts text }
        @push_spec = spec_with_path(@push_podspec_file)
        check_pod_http_source_publish
      end

      def save_new_version_to_local_podspec
        text = File.read(@name)
        version = @version_number.to_s
        version = "#{@version_number}.b#{@beta_version_number}" if @beta_version_publish
        text.gsub!("s.version          = '#{@old_version}'", "s.version          = '#{version}'")
        File.open(@name, 'w') { |file| file.puts text }
      end

      # 恢复旧版本
      def restore_old_version_to_podspec
        text = File.read(@name)
        version = code_version
        text.gsub!("s.version          = '#{version}'", "s.version          = '#{@old_version}'")
        File.open(@name, 'w') { |file| file.puts text }
      end

      def save_new_default_subspec(subspec)
        content = File.read(@push_podspec_file)
        old_subspec = 'Core_Framework'
        old_subspec = 'CoreFramework' unless content.include?("s.subspec 'Core_Framework'")
        # 替换组件default_subspec
        content = content.gsub(/s.subspec '#{old_subspec}'/, "s.subspec '#{old_subspec}_1'")
        content = content.gsub(/s.subspec '#{subspec}_Framework'/, "s.subspec '#{old_subspec}'")
        File.open(@push_podspec_file, 'w') { |file| file.puts content }
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
      def modify_zip_path(zip_path)
        content = File.open(@push_podspec_file).read
        content_lines = content.lines

        # 删除包含 zip_file_path = 的所有行
        content_lines.reject! do |line|
          line.include?('zip_file_path =') || line.include?('git_source = ') || line.include?('以下为脚本依赖CoreFramework')
        end

        # 重新组合内容
        content = content_lines.join

        http_source = <<~SPEC
          s.source = {
                :http => "https://gitlab.v.show/api/v4/projects/#{get_project_id}/#{zip_path}%2F#{@new_spec_name}-#{@new_version}.zip/raw?ref=main",
                :type => "zip",
                :headers => ["Authorization: Bearer \#{ENV['GIT_LAB_TOKEN']}"]
              }
        SPEC

        framework_spec_contents = content.gsub(/\s{2}s\.subspec 'CoreFramework[\w\W]*?\bend/).to_a
        if framework_spec_contents.empty?
          framework_spec_contents = content.gsub(/\s{2}s\.subspec 'Core_Framework[\w\W]*?\bend/).to_a
          if framework_spec_contents.empty?
            puts "-> podspec配置不正确，请检查#{@name} CoreFramework字段。".red
            clean
            Process.exit(1)
          end
        end

        framework_spec_content = framework_spec_contents.first.to_s
        new_framework_spec_content = framework_spec_content.gsub(@spec.name, @new_spec_name)
        new_framework_spec_content.gsub!('ss.', 's.')
        new_framework_spec_content.gsub!(/s.subspec .*/, '')
        new_framework_spec_content.gsub!(/\s{2}end/, '')

        content.gsub!(/.*?(?=Pod::Spec\.new do \|s\|)/m, '')
        content.gsub!(/if use_framework.*?end/m, http_source.rstrip)
        content.gsub!(framework_spec_content, new_framework_spec_content.strip)
        content.gsub!(/\s{2}s\.subspec *.[\w\W]*?\bend/m, '')
        content.gsub!(/\s{2}s\.test_spec *.[\w\W]*?\bend/m, '')
        content.gsub!(/\n{2,}/, "\n\n")
        content.gsub!('    ', '  ')
        content.gsub!('s.vendored_frameworks', '  s.vendored_frameworks')
        content.gsub!(/\s{2}s.homepage\s{5}=.*/, "  s.homepage     = \"https://gitlab.v.show/ios_framework/\#{s.name.to_s}.git\"")
        File.open(@push_podspec_file, 'w') { |file| file.puts content.strip }
      end

      # 适配新的文件保存路径
      def check_pod_http_source_publish
        content = File.open(@push_podspec_file).read.to_s
        # 已添加subspec跳过
        return if content.include?('zip_file_path = ')

        zip_file_path = get_zip_path(@new_version)

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
          command = Repo::Push::PushWithoutValid.new(argv)
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
        version = @push_spec.attributes_hash['version']
        UI.puts "-> 正在发布新版本(#{version})...".yellow unless @from_wukong
        config.silent = true
        argv = CLAide::ARGV.coerce([@source, @push_podspec_file, '--allow-warnings', "--sources=#{@sources.join(',')}"])
        begin
          command = Repo::Push::PushWithoutValid.new(argv)
          command.run
          config.silent = false
          UI.puts "-> (#{version})发布成功！".green unless @from_wukong
          config.silent = true
        rescue StandardError => e
          clean
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