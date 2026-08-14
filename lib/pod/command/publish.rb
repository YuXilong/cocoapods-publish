# frozen_string_literal: true

require 'English'
require 'base64'
require 'cocoapods-publish/git_push_retry'
require 'json'
require 'open3'
require 'pod/command/auto'
require 'uri'

module Pod
  class Command
    class Publish < Command
      include GitPushRetry

      self.summary = '自动发布组件到私有组件仓库.'

      self.arguments = [
        CLAide::Argument.new('NAME', true)
      ]

      def self.options
        [
          %w[--skip-import-validation 跳过import_validation验证.],
          %w[--skip-lib-lint 跳过lib验证.],
          %w[--sources 指定依赖的组件仓库.],
          %w[--publish-framework 指定发布framework.],
          %w[--from-wukong 发起者为`wukong`],
          %w[--debug 输出详细构建日志],
          %w[--beta 发布beta版本],
          %w[--subspecs 同时构建的subspec],
          %w[--mixup-publish 混淆],
          %w[--only-mixup 仅发布混淆二进制版本，不读取或发布普通版产物],
          %w[--new-class-prefixes 混淆时要修改的目标类前缀，多个用,隔开.默认为：`MNL,PPL`],
        ]
      end

      def initialize(argv)
        @source = argv.shift_argument
        @name = argv.shift_argument
        @skip_import_validation = argv.flag?('skip-import-validation', false)
        @skip_lib_lint = argv.flag?('skip-lib-lint', false)
        @sources = argv.option('sources', 'trunk,BaiTuPods,BaiTuFrameworkPods').split(',')
        @spec = spec_with_path(@name)
        @publish_framework = argv.flag?('publish-framework', false) || @source.eql?('BaiTuFrameworkPods')
        @from_wukong = argv.flag?('from-wukong', false)
        @debug = argv.flag?('debug', false)

        # 构建子subspec支持
        subspecs = argv.option('subspecs')
        @subspecs = if subspecs.nil?
                      []
                    else
                      subspecs.split(',')
                    end

        # 发布beta版本
        @beta_version_publish = argv.flag?('beta', false)

        @swift_version = local_swift_version

        # 发布到GitHub源码
        @to_github = argv.flag?('to-github', false)

        # 是否混淆
        @mixup_publish = argv.flag?('mixup-publish', false)
        @only_mixup = argv.flag?('only-mixup', false)

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

        # 属性混淆标志位
        mixup_property_class_prefixes = argv.option('mixup-property-class-prefixes')
        @mixup_property_class_prefixes = if mixup_property_class_prefixes.nil?
                                            []
                                          else
                                            mixup_property_class_prefixes.split(',')
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
          # 'MNL' => 'mimi',
          # 'MTI' => 'miti',
          # 'MIU' => 'miu',
          # 'ZSL' => 'jolly',
          # 'PPL' => 'poppolite'
        }
        @current_branch = get_current_branch.upcase
        @pod_name = @spec.name

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

        config.silent = !@debug
        begin
          commit_and_push_component_repository!(version, branch)
        rescue ::StandardError => e
          config.silent = false
          puts "-> 代码提交失败：#{e.message}".red
          Process.exit(1)
        end
        config.silent = false
      end

      def git_dirty?
        status = `git status --porcelain`
        !status.strip.empty?
      end


      def push_mixup_pods
        unless @only_mixup
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
        @artifact_manifest = artifact_manifest_for_version(zip_file_path, version)
        validate_artifact_manifest!(@artifact_manifest)
        validate_artifact_zip_identity!(@artifact_manifest, zip_file_path, version)
        modify_zip_path(zip_file_path, @artifact_manifest)
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
        config.silent = !@debug
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
        "#{version_without_swift_suffix(version)}.#{append_meta}"
      end

      def version_for_subspec(subspec)
        version = version_without_swift_suffix(@main_version)
        if version.include?(".#{@current_branch}")
          version = version.gsub(".#{@current_branch}", ".#{subspec}.#{@current_branch}")
        end
        version = "#{version}.#{subspec}" unless version.include?(".#{@current_branch}")
        version
      end

      # 迁移期间允许从历史 podspec 继续发布，但所有新版本统一使用业务版本号。
      def version_without_swift_suffix(version)
        version.sub(/\.swift-\d+(?:\.\d+)*\z/, '')
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
          return new_version
        end

        if @beta_version_publish
          # beta版本
          new_version = "#{@version_number}.b#{@beta_version_number}"
          return new_version
        end

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
        version = "#{version}.#{@current_branch}" if @is_version_need_attach_branch
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
      def modify_zip_path(zip_path, artifact_manifest = @artifact_manifest)
        validate_artifact_manifest!(artifact_manifest)
        content = File.open(@push_podspec_file).read
        content_lines = content.lines
        host = (ENV['GIT_LAB_HOST']).to_s.freeze

        # 删除包含 zip_file_path = 的所有行
        content_lines.reject! do |line|
          line.include?('zip_file_path =') || line.include?('git_source = ') || line.include?('以下为脚本依赖CoreFramework') || line.include?('s.default_subspec =')
        end

        # 重新组合内容
        content = content_lines.join

        http_source = <<~SPEC
          s.source = {
                :http => "https://#{host}/api/v4/projects/#{get_project_id}/#{zip_path}%2F#{@new_spec_name}-#{@new_version}.zip/raw?ref=main",
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
        new_framework_spec_content = rewrite_primary_framework_reference(
          new_framework_spec_content,
          artifact_manifest.fetch('artifact').fetch('path')
        )

        content.gsub!(/.*?(?=Pod::Spec\.new do \|s\|)/m, '')
        content.gsub!(/if use_framework.*?end/m, http_source.rstrip)
        content.gsub!(framework_spec_content, new_framework_spec_content.strip)
        content.gsub!(/\s{2}s\.subspec *.[\w\W]*?\bend/m, '')
        content.gsub!(/\s{2}s\.default_subspec = 'Core'/m, '')
        content.gsub!(/\s{2}s\.test_spec *.[\w\W]*?\bend/m, '')
        content.gsub!(/\n{2,}/, "\n\n")
        content.gsub!('    ', '  ')
        content.gsub!('s.vendored_frameworks', '  s.vendored_frameworks')
        content.gsub!(/\s{2}s.homepage\s{5}=.*/, "  s.homepage     = \"https://#{host}/ios_framework/\#{s.name.to_s}.git\"")
        content = remove_legacy_architecture_overrides(content)
        File.open(@push_podspec_file, 'w') { |file| file.puts content.strip }
      end

      def artifact_manifest_for_version(zip_path, version)
        directory = zip_path.sub(%r{\Arepository/files/}, '')
        filename = "#{@new_spec_name}-#{version}.artifact.json"
        repository_path = URI.encode_www_form_component(File.join(directory, filename))
        response = send_request(
          GET,
          "/projects/#{get_project_id}/repository/files/#{repository_path}",
          { 'ref' => 'main' }
        )
        encoded_content = response['content'].to_s
        raise Informative, "远端产物缺少 #{filename}" if encoded_content.empty?

        JSON.parse(Base64.decode64(encoded_content))
      rescue JSON::ParserError, ArgumentError => e
        raise Informative, "#{filename} 内容无效：#{e.message}"
      end

      def validate_artifact_manifest!(manifest)
        raise Informative, '缺少 artifact manifest，拒绝发布二进制版本' unless manifest.is_a?(Hash)
        raise Informative, 'artifact manifest schema_version 不受支持' unless manifest['schema_version'] == 1

        component = manifest['component'] || {}
        unless component['name'] == @new_spec_name && component['version'].to_s == @new_version.to_s
          raise Informative,
                "artifact manifest 与待发布版本不匹配：期望 #{@new_spec_name} #{@new_version}，" \
                "实际 #{component['name']} #{component['version']}"
        end

        artifact = manifest['artifact'] || {}
        expected_artifact = "#{@new_spec_name}.xcframework"
        unless artifact['type'] == 'xcframework' && artifact['path'] == expected_artifact
          raise Informative, "主产物必须是 #{expected_artifact}"
        end
        unless %w[static dynamic].include?(artifact['linkage'])
          raise Informative, 'artifact manifest 缺少有效 linkage'
        end

        ios = manifest.dig('platforms', 'ios') || {}
        device = ios['device'] || {}
        unless device['status'] == 'supported' && device['architectures'].is_a?(Array) && !device['architectures'].empty?
          raise Informative, 'XCFramework 缺少有效的 iOS 真机切片'
        end

        simulator = ios['simulator'] || {}
        simulator_archs = simulator['architectures']
        simulator_valid =
          if simulator['status'] == 'supported'
            simulator_archs.is_a?(Array) && !simulator_archs.empty?
          elsif simulator['status'] == 'unavailable'
            simulator_archs == []
          else
            false
          end
        raise Informative, 'artifact manifest 的模拟器能力声明无效' unless simulator_valid

        unless manifest.dig('integrity', 'validated') == true
          raise Informative, '构建端未完成 XCFramework 完整性校验'
        end
        distribution = manifest['distribution'] || {}
        expected_zip = "#{@new_spec_name}-#{@new_version}.zip"
        unless distribution['zip_file'] == expected_zip &&
               distribution['sha256'].to_s.match?(/\A[0-9a-f]{64}\z/i) &&
               distribution['size'].is_a?(Integer) && distribution['size'].positive?
          raise Informative, "artifact manifest 缺少有效的 ZIP 身份：#{expected_zip}"
        end

        debug_symbols = manifest['debug_symbols']
        raise Informative, 'artifact manifest 缺少 debug_symbols 声明' unless debug_symbols.is_a?(Array)
        debug_symbols.each do |symbols|
          path = symbols['path'].to_s
          if path.empty? || Pathname(path).absolute? || path.split(File::SEPARATOR).include?('..') ||
             !path.start_with?("#{expected_artifact}/")
            raise Informative, "dSYM 路径无效：#{path}"
          end
          raise Informative, "dSYM UUID 声明无效：#{path}" unless symbols['uuids'].is_a?(Array)
        end

        if artifact['linkage'] == 'dynamic'
          required_variants = simulator['status'] == 'supported' ? %w[device simulator] : ['device']
          symbol_variants = debug_symbols.filter_map do |symbols|
            symbols['variant'] unless symbols['uuids'].empty?
          end
          missing = required_variants - symbol_variants
          raise Informative, "动态 XCFramework 缺少 #{missing.join(', ')} dSYM/UUID" unless missing.empty?
        end

        if simulator['status'] == 'unavailable'
          UI.puts "-> #{@new_spec_name} #{@new_version} 仅支持真机，继续发布 device-only XCFramework"
        end
        manifest
      end

      def validate_artifact_zip_identity!(manifest, zip_path, version)
        distribution = manifest.fetch('distribution')
        zip_file = "#{@new_spec_name}-#{version}.zip"
        directory = zip_path.sub(%r{\Arepository/files/}, '')
        repository_path = URI.encode_www_form_component(File.join(directory, zip_file))
        headers = send_request(
          HEAD,
          "/projects/#{get_project_id}/repository/files/#{repository_path}",
          { 'ref' => 'main' }
        )

        actual_sha256 = headers['x-gitlab-content-sha256'].to_s
        actual_size = headers['x-gitlab-size'].to_i
        unless distribution['zip_file'] == zip_file &&
               distribution['sha256'].to_s.casecmp?(actual_sha256) &&
               distribution['size'] == actual_size
          raise Informative, "#{zip_file} 与 artifact manifest 的 SHA-256/大小不一致，拒绝发布"
        end
        manifest
      end

      def remove_legacy_architecture_overrides(content)
        keys = [
          'VALID_ARCHS',
          'EXCLUDED_ARCHS[sdk=iphonesimulator*]',
        ]
        assignment = /(?<prefix>^[ \t]*(?:s|ss)\.(?:pod_target_xcconfig|user_target_xcconfig)\s*=\s*\{)(?<body>[^{}]*)(?<suffix>\})[ \t]*\n?/m

        content.gsub(assignment) do
          prefix = Regexp.last_match[:prefix]
          suffix = Regexp.last_match[:suffix]
          body = Regexp.last_match[:body].dup
          keys.each do |key|
            body.gsub!(/(['"])#{Regexp.escape(key)}\1\s*=>\s*[^,\n}]+,?/, '')
          end
          body.gsub!(/,\s*,/, ',')
          body.gsub!(/,\s*\z/, '')
          next '' if body.gsub(/[\s,]/, '').empty?

          "#{prefix}#{body}#{suffix}\n"
        end
      end

      def rewrite_primary_framework_reference(content, artifact_path)
        framework_names = [@new_spec_name]
        framework_names << @spec.name if defined?(@spec) && @spec
        rewritten = content.dup
        replaced = false

        framework_names.compact.uniq.each do |name|
          pattern = /(?<![A-Za-z0-9_])#{Regexp.escape(name)}\.framework(?![A-Za-z0-9_])/
          rewritten.gsub!(pattern) do
            replaced = true
            artifact_path
          end
        end
        rewritten.gsub!(/#\{s\.name(?:\.to_s)?\}\.framework/) do
          replaced = true
          artifact_path
        end

        unless replaced || rewritten.include?(artifact_path)
          raise Informative, "CoreFramework 未精确引用 #{@new_spec_name}.framework，无法安全改写主产物"
        end
        rewritten
      end

      def artifact_capability_record(manifest)
        simulator = manifest.dig('platforms', 'ios', 'simulator')
        {
          'name' => manifest.dig('component', 'name'),
          'version' => manifest.dig('component', 'version'),
          'format' => manifest.dig('artifact', 'type'),
          'device' => manifest.dig('platforms', 'ios', 'device', 'architectures'),
          'simulator' => simulator['architectures'],
          'status' => simulator['status'] == 'supported' ? 'supported' : 'device_only',
        }
      end

      def emit_artifact_capability(manifest)
        puts "-> [WK_ARTIFACT] #{JSON.generate(artifact_capability_record(manifest))}"
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
        create_tag
      end

      def check_tag
        output = `cd #{@project_path} && git tag -l #{@new_version}`.lines.to_a
        output.empty?
      end

      # 创建tag
      def create_tag
        UI.puts '-> 创建新版本...'.yellow unless @from_wukong
        branch = get_current_branch

        config.silent = !@debug
        begin
          commit_and_push_component_repository!(@new_version, branch)
          recreate_and_push_component_tag!(@new_version)
        rescue ::StandardError => e
          config.silent = false
          UI.puts "-> 创建新版本失败：#{e.message}".red
          restore_old_version_to_podspec
          Process.exit(1)
        end
        UI.puts
        config.silent = false

        UI.puts "-> 新版本(#{@new_version})创建成功！".green unless @from_wukong
      end

      def push_sources
        UI.puts '-> 推送代码...'.yellow unless @from_wukong
        branch = get_current_branch

        config.silent = !@debug
        begin
          commit_and_push_component_repository!(@new_version, branch)
        rescue ::StandardError => e
          config.silent = false
          UI.puts "-> 代码推送失败：#{e.message}".red
          restore_old_version_to_podspec
          Process.exit(1)
        end
        UI.puts
        config.silent = false

        UI.puts '-> 推送代码成功！'.green unless @from_wukong
      end

      def get_current_branch
        run_project_git!('symbolic-ref', '--short', 'HEAD').strip
      end

      def commit_and_push_component_repository!(version, branch)
        sync_component_repository!(branch)
        run_project_git!('add', '.')
        run_project_git!(*git_commit_arguments(version))
        push_component_branch_with_retry!(branch)
      end

      def sync_component_repository!(branch)
        run_project_git!('fetch', 'origin', branch)
        run_project_git!('rebase', '--autostash', "origin/#{branch}")
      rescue ::StandardError
        abort_component_rebase
        raise
      end

      def push_component_branch_with_retry!(branch)
        attempts = 1
        begin
          run_project_git!(*git_push_branch_arguments(branch))
        rescue ::StandardError => e
          raise unless retry_git_push?(e, attempts)

          log_component_push_retry(attempts)
          sync_component_repository!(branch)
          attempts += 1
          retry
        end
      end

      def log_component_push_retry(attempts)
        max_retries = GitPushRetry::MAX_GIT_PUSH_ATTEMPTS - 1
        message = "-> 检测到组件仓库并发更新，拉取并 rebase 后重试 (#{attempts}/#{max_retries})"
        UI.puts message.yellow
      end

      def abort_component_rebase
        run_project_git!('rebase', '--abort')
      rescue ::StandardError
        nil
      end

      def recreate_and_push_component_tag!(tag)
        run_project_git_ignoring_failure('tag', '-d', tag)
        run_project_git!(*git_tag_arguments(tag))
        run_project_git_ignoring_failure(*git_delete_remote_tag_arguments(tag))
        run_project_git!(*git_push_tag_arguments(tag))
      end

      def run_project_git!(*arguments)
        stdout, stderr, status = Open3.capture3(
          'git', *arguments, chdir: project_git_directory
        )
        return stdout if status.success?

        output = [stdout, stderr].reject(&:empty?).join("\n").strip
        raise Informative, "Git 命令失败：git #{arguments.join(' ')}\n#{output}"
      end

      def run_project_git_ignoring_failure(*arguments)
        run_project_git!(*arguments)
      rescue Informative
        nil
      end

      def project_git_directory
        return @project_path unless @project_path.to_s.empty?
        return Pathname(@name).expand_path.dirname.to_s unless @name.to_s.empty?

        Dir.pwd
      end

      def git_commit_arguments(version)
        ['commit', '--no-verify', '-m', "[Update] (#{version})"]
      end

      def git_push_branch_arguments(branch)
        ['push', '--no-verify', 'origin', branch, '--quiet']
      end

      def git_push_tag_arguments(tag)
        ['push', '--no-verify', 'origin', "refs/tags/#{tag}", '--force', '--quiet']
      end

      def git_delete_remote_tag_arguments(tag)
        ['push', '--no-verify', 'origin', ":refs/tags/#{tag}", '--quiet']
      end

      def git_tag_arguments(tag)
        ['tag', '-a', tag, '-m', "[Update] (#{tag})"]
      end

      # 推送新版本到私有库
      def push_pods
        UI.puts "-> 发布新版本(#{@new_version})...".yellow unless @from_wukong
        config.silent = !@debug
        argv = CLAide::ARGV.coerce([@source, @name, '--allow-warnings', "--sources=#{@sources.join(',')}"])
        begin
          command = Repo::Push::PushWithoutValid.new(argv)
          command.run
          config.silent = false
          UI.puts "-> (#{@new_version})发布成功！".green unless @from_wukong
          config.silent = !@debug
        rescue ::StandardError => e
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
        config.silent = !@debug
        argv = CLAide::ARGV.coerce([@source, @push_podspec_file, '--allow-warnings', "--sources=#{@sources.join(',')}"])
        begin
          emit_artifact_capability(@artifact_manifest)
          command = Repo::Push::PushWithoutValid.new(argv)
          command.run
          config.silent = false
          UI.puts "-> (#{version})发布成功！".green unless @from_wukong
          config.silent = !@debug
        rescue ::StandardError => e
          clean
          config.silent = false
          UI.puts "-> (#{version})发布失败：#{e.message}".red
          Process.exit(1)
        end
      end

      def push_pod_to_github
        version = @spec.attributes_hash['version']
        UI.puts "-> 正在发布新版本(#{version})...".yellow unless @from_wukong
        config.silent = !@debug
        argv = CLAide::ARGV.coerce([@source, @name, '--allow-warnings', '--sources=trunk'])
        begin
          command = Repo::Push::PushWithoutValid.new(argv)
          command.run
          command = Repo::Update.new(CLAide::ARGV.coerce([@source]))
          command.run
          config.silent = false
          UI.puts "-> (#{version})发布成功！".green unless @from_wukong
          config.silent = !@debug
        rescue ::StandardError => e
          restore_old_version_to_podspec if @beta_version_publish
          config.silent = false
          UI.puts "-> (#{version})发布失败：#{e.message}".red
          Process.exit(1)
        end
      end
    end
  end
end
