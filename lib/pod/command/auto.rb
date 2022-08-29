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
            %w[--skip-lib-lint 跳过lib验证.],
            %w[--skip-package 跳过lib验证.]
          ]
        end

        def initialize(argv)
          @podspec_root = argv.shift_argument
          @local = argv.flag?('local', true)
          @skip_lib_lint = argv.flag?('skip-lib-lint', false)
          @skip_package = argv.flag?('skip-package', false)
          super
        end

        def validate!; end

        def run
          @podspec_root ||= Dir.pwd
          @podspec = find_podspec_file
          # 打包
          unless @skip_package
            argv = CLAide::ARGV.coerce(@local ? [@podspec, '--local', '--no-show-tips'] : [@podspec])
            Pod::Command::Package.new(argv).run
          end

          # 发布源码
          puts '-> 正在发布到源码私有库...'.yellow
          argv = CLAide::ARGV.coerce(@skip_lib_lint ? ['BaiTuPods', @podspec, '--skip-lib-lint'] : ['BaiTuPods', @podspec])
          Publish.new(argv).run
          puts '-> 已发布到源码私有库'.green

          # 发布二进制
          puts '-> 正在发布到二进制私有库...'.yellow
          argv = CLAide::ARGV.coerce(['BaiTuFrameworkPods', @podspec])
          Publish.new(argv).run
          puts '-> 已发布到二进制私有库'.green
        end

        # 自动查找当前目前的podspec文件
        def find_podspec_file
          Dir.chdir(@podspec_root)
          files = []
          Dir.glob('*.podspec')
             .each { |path| files << path }

          if files.empty?
            puts '-> 未找到.podspec配置文件'.red
            Process.exit
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
              Process.exit
            end
          end

          files[index - 1]
        end
      end
    end
  end
end

