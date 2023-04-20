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
            %w[--old-class-prefix 混淆时修改的类前缀.默认为：`BT`],
            %w[--new-class-prefixes 混淆时要修改的目标类前缀，多个用,隔开.默认为：`MNL,PPL`],
            %w[--filter-file-prefixes 混淆时要忽略的文件前缀，多个用,隔开.默认为：`Target_`],
            %w[--from-wukong 发起者为`wukong`],
            %w[--v2 使用`v2`构建系统],
            %w[--beta 发布beta版本]
          ]
        end

        def initialize(argv)
          @podspec_root = argv.shift_argument
          @local = argv.flag?('local', true)
          @lib_lint = argv.flag?('lib-lint', false)
          @skip_package = argv.flag?('skip-package', false)

          # 代码混淆配置项
          @mixup = argv.flag?('mixup', false)
          @old_class_prefix = argv.option('old-class-prefix', 'BT')
          @new_class_prefixes = argv.option('new-class-prefixes', 'MNL,PPL')
          @filter_file_prefixes = argv.option('filter-file-prefixes', 'Target_,')

          # 更新本地缓存
          @clean_cache = argv.flag?('clean-cache', false)

          # 使用`v2`构建系统
          @use_build_v2 = argv.flag?('v2', false)

          # 发布beta版本
          @beta_version_auto = argv.flag?('beta', false)

          # 仅打混淆包
          @only_mixup_auto = argv.flag?('only-mixup', false)

          super
        end

        def validate!; end

        def run
          @podspec_root ||= Dir.pwd
          @podspec = find_podspec_file

          # 打包
          unless @skip_package
            puts '-> 正在生成二进制...'.yellow unless @from_wukong

            args = [@podspec]
            args.push('--local', '--no-show-tips') if @local
            args.push('--clean-cache') if @clean_cache
            args.push('--mixup') if @mixup
            args.push('--from-wukong') if @from_wukong
            args.push('--v2') if @use_build_v2
            args.push('--beta') if @beta_version_auto
            args.push('--only-mixup') if @only_mixup_auto
            args.push("--new-class-prefixes=#{@new_class_prefixes}") if @mixup
            args.push("--old-class-prefix=#{@old_class_prefix}") if @mixup
            args.push("--filter-file-prefixes=#{@filter_file_prefixes}") if @mixup

            argv = CLAide::ARGV.coerce(args)
            Pod::Command::Package.new(argv).run
            puts '-> 二进制生成成功！'.yellow unless @from_wukong
          end

          puts '-> 正在发布...'.yellow if @from_wukong

          unless @beta_version_auto
            # 发布源码
            begin_time = (Time.now.to_f * 1000).to_i
            puts '-> 正在发布到源码私有库...'.yellow unless @from_wukong
            params = @lib_lint ? ['BaiTuPods', @podspec] : ['BaiTuPods', @podspec, '--skip-lib-lint']
            params << '--from-wukong' if @from_wukong
            argv = CLAide::ARGV.coerce(params)
            Publish.new(argv).run
            end_time = (Time.now.to_f * 1000).to_i
            duration = end_time - begin_time
            puts "-> 已发布到源码私有库 [#{duration / 1000.0} sec]".green
          end

          # 发布二进制
          begin_time = (Time.now.to_f * 1000).to_i
          puts '-> 正在发布到二进制私有库...'.yellow unless @from_wukong
          params = ['BaiTuFrameworkPods', @podspec]
          params << '--from-wukong' if @from_wukong
          params << '--beta' if @beta_version_auto
          argv = CLAide::ARGV.coerce(params)
          Publish.new(argv).run
          end_time = (Time.now.to_f * 1000).to_i
          duration = end_time - begin_time
          puts "-> 已发布到二进制私有库 [#{duration / 1000.0} sec]".green
          puts '-> 发布完成'.green unless @from_wukong
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
            index = gets.to_i

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

