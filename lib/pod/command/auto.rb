module Pod
  class Command
    class Publish < Command
      # 一键打包发布命令
      class Auto < Publish
        self.summary = '自动打包、发布组件到私有源码、二进制组件仓库.'

        self.arguments = [
          CLAide::Argument.new('NAME.podspec', false)
        ]

        def self.options
          [
            %w[--local 指定使用本地版本构建二进制.],
            %w[--lib-lint lib验证.],
            %w[--skip-package 跳过制作二进制.],
            %w[--clean-cache 构建时清除本地所有的组件缓存.⚠️注意：开启后会重新下载所有组件],
            %w[--mixup 开启构建时代码混淆功能.],
            %w[--mixup-func-class-prefixes 开启构建时函数混淆功能.],
            %w[--old-class-prefix 混淆时修改的类前缀.默认为：`BT`],
            %w[--new-class-prefixes 混淆时要修改的目标类前缀，多个用,隔开],
            %w[--filter-file-prefixes 混淆时要忽略的文件前缀，多个用,隔开.默认为：`Target_`],
            %w[--from-wukong 发起者为`wukong`],
            %w[--beta 发布beta版本],
            %w[--upgrade-swift 升级Swift版本],
            %w[--continue-from-upload 从上传任务恢复发布],
            %w[--subspecs 同时构建的subspec]
          ]
        end

        def initialize(argv)
          @podspec_root = argv.shift_argument
          @local = argv.flag?('local', true)
          @lib_lint = argv.flag?('lib-lint', false)
          @skip_package = argv.flag?('skip-package', false)

          # 构建子subspec支持
          @auto_subspecs = argv.option('subspecs')

          # 代码混淆配置项
          @auto_mixup = argv.flag?('mixup', false)
          @auto_mixup_func_class_prefixes = argv.option('mixup-func-class-prefixes', '')
          @auto_old_class_prefix = argv.option('old-class-prefix', 'BT')
          @auto_new_class_prefixes = argv.option('new-class-prefixes', '')
          @auto_filter_file_prefixes = argv.option('filter-file-prefixes', 'Target_,')

          # 更新本地缓存
          @clean_cache = argv.flag?('clean-cache', false)

          # 发布beta版本
          @beta_version_auto = argv.flag?('beta', false)

          # 仅打混淆包
          @only_mixup_auto = argv.flag?('only-mixup', false)

          # 发布到GitHub
          @publish_to_github_auto = argv.flag?('publish-to-github', false)

          # 升级Swift版本
          @upgrade_swift_auto = argv.flag?('upgrade-swift', false)

          # 从上传任务恢复
          @continue_from_upload_auto = argv.flag?('continue-from-upload', false)

          super
        end

        def validate!; end

        def run
          @podspec_root ||= Dir.pwd
          @podspec = find_podspec_file
          @is_assets_framework = @podspec.include?('BTAssets.podspec')

          if @beta_version_auto && get_current_branch == 'main'
            puts 'main分支不支持发布Beta组件！'.red if @from_wukong
            puts '-> main分支不支持发布Beta组件！'.red unless @from_wukong
            Process.exit(1)
          end

          if @continue_from_upload_auto
            puts '-> 正在恢复上传版本...'.yellow

            args = [@podspec]
            args.push('--continue-from-upload') if @continue_from_upload_auto
            args.push('--local', '--no-show-tips') if @local
            args.push('--clean-cache') if @clean_cache
            args.push("--subspecs=#{@auto_subspecs}") unless @auto_subspecs.nil?
            args.push('--mixup') if @auto_mixup
            args.push("--mixup-func-class-prefixes=#{@auto_mixup_func_class_prefixes}") if @auto_mixup
            args.push('--from-wukong') if @from_wukong
            args.push('--beta') if @beta_version_auto
            args.push('--upgrade-swift') if @upgrade_swift_auto
            args.push('--only-mixup') if @only_mixup_auto
            args.push("--new-class-prefixes=#{@auto_new_class_prefixes}") if @auto_mixup
            args.push("--old-class-prefix=#{@auto_old_class_prefix}") if @auto_mixup
            args.push("--filter-file-prefixes=#{@auto_filter_file_prefixes}") if @auto_mixup

            argv = CLAide::ARGV.coerce(args)
            Pod::Command::Package.new(argv).run
            puts '-> 恢复上传成功！'.yellow unless @from_wukong
          else
            # 打包
            unless @skip_package
              puts '-> 正在生成二进制...'.yellow unless @from_wukong

              args = [@podspec]
              args.push('--local', '--no-show-tips') if @local
              args.push('--clean-cache') if @clean_cache
              args.push("--subspecs=#{@auto_subspecs}") unless @auto_subspecs.nil?
              args.push('--mixup') if @auto_mixup
              args.push("--mixup-func-class-prefixes=#{@auto_mixup_func_class_prefixes}") if @auto_mixup
              args.push('--from-wukong') if @from_wukong
              args.push('--beta') if @beta_version_auto
              args.push('--upgrade-swift') if @upgrade_swift_auto
              args.push('--only-mixup') if @only_mixup_auto
              args.push("--new-class-prefixes=#{@auto_new_class_prefixes}") if @auto_mixup
              args.push("--old-class-prefix=#{@auto_old_class_prefix}") if @auto_mixup
              args.push("--filter-file-prefixes=#{@auto_filter_file_prefixes}") if @auto_mixup

              argv = CLAide::ARGV.coerce(args)
              Pod::Command::Package.new(argv).run
              puts '-> 二进制生成成功！'.yellow unless @from_wukong
            end
          end

          puts '-> 正在发布...'.yellow if @from_wukong

          # BTAssets不发布源码版本
          should_increase_version = true
          if !@beta_version_auto && !@upgrade_swift_auto && !@is_assets_framework
            # 发布源码
            begin_time = (Time.now.to_f * 1000).to_i
            puts '-> 正在发布到源码私有库...'.yellow
            params = @lib_lint ? ['BaiTuPods', @podspec] : ['BaiTuPods', @podspec, '--skip-lib-lint']
            params << '--from-wukong' if @from_wukong
            params << "--new-class-prefixes=#{@auto_new_class_prefixes}"
            params << "--mixup-func-class-prefixes=#{@auto_mixup_func_class_prefixes}"
            argv = CLAide::ARGV.coerce(params)
            Publish.new(argv).run
            end_time = (Time.now.to_f * 1000).to_i
            duration = end_time - begin_time
            puts "-> 已发布到源码私有库 [#{duration / 1000.0} sec]".green
            should_increase_version = false
          end

          # 发布二进制
          begin_time = (Time.now.to_f * 1000).to_i
          puts '-> 正在发布到二进制私有库...'.yellow
          params = ['BaiTuFrameworkPods', @podspec]
          params << '--from-wukong' if @from_wukong
          params << '--beta' if @beta_version_auto
          params << "--subspecs=#{@auto_subspecs}" unless @auto_subspecs.nil?
          params << '--upgrade-swift' if @upgrade_swift_auto
          params << '--mixup-publish' if @auto_mixup
          params << "--new-class-prefixes=#{@auto_new_class_prefixes}"
          params << "--mixup-func-class-prefixes=#{@auto_mixup_func_class_prefixes}"
          params << '--no-increase-version' unless should_increase_version
          argv = CLAide::ARGV.coerce(params)
          Publish.new(argv).run
          end_time = (Time.now.to_f * 1000).to_i
          duration = end_time - begin_time
          puts "-> 已发布到二进制私有库 [#{duration / 1000.0} sec]".green
          puts '-> 发布完成'.green unless @from_wukong

        end

        def get_current_branch
          `git symbolic-ref --short HEAD`.to_s.chomp
        end

        # 自动查找当前目前的podspec文件
        def find_podspec_file
          Dir.chdir(@podspec_root)
          files = []
          Dir.glob('*.podspec')
             .each { |path| files << path }

          if files.empty?
            puts '-> 未找到.podspec配置文件'.red
            Process.exit(1)
          end

          index = 1
          if files.count > 1
            puts '-> 发现多个podspec配置文件，请选择一个：'.green
            files.each_with_index do |f, i|
              puts "-> #{i + 1}.#{f}".green
            end
            index = gets.chomp.to_i

            unless (1...files.count + 1).include?(index)
              puts '-> 输入不正确，请重试！'.red
              Process.exit(1)
            end
          end

          files[index - 1]
        end
      end
    end
  end
end

