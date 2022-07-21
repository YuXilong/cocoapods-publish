module Pod
  class Command
    class Publish < Command
      self.summary = '自动发布组件到私有组件仓库.'

      self.arguments = [
        CLAide::Argument.new('NAME', true)
      ]

      def initialize(argv)
        @name = argv.shift_argument
        @source = ''
        super
      end

      def validate!
        super
        help! 'A Pod name is required.' unless @name
      end

      def run
        # UI.puts "Add your implementation for the cocoapods-publish plugin in #{__FILE__}"
        # validate_podspec
        @spec ||= Pod::Specification.from_file('/Users/yuxilong/Desktop/code/BaiTuPods/BTBaseKit/BTBaseKit.podspec')
        version = @spec.attributes_hash['version']
        version = '1.0.2'
        @spec.attributes_hash['version'] = version
        puts @spec
      end

      def validate_pod
        UI.puts "-> 验证#{@name}...".yellow

        argv = CLAide::ARGV.coerce([@name, '--allow-warnings', '--verbose', '--sources=trunk,BaiTuPods,BaiTuFrameworkPods'])
        command = Lib::Lint.new(argv)
        output = command.run
        # lint = Lib::Lint.new(argv)
        # command = "pod lib lint #{@name} --allow-warnings --verbose --sources=trunk,BaiTuPods,BaiTuFrameworkPods"
        # # output = `#{command}`.lines.to_a
        # output = lint.run
        if $?.exitstatus != 0
          puts output.join('')
          UI.puts "-> #{@name} 验证未通过！Command: #{command}".red
          Process.exit
        end
        UI.puts "-> #{@name} 验证通过！".green
      end

      def spec
        @spec ||= Pod::Specification.from_file('/Users/yuxilong/Desktop/code/BaiTuPods/BTBaseKit/BTBaseKit.podspec')
      rescue Informative => e # TODO: this should be a more specific error
        raise Informative, 'Unable to interpret the specified path ' \
                             "#{UI.path(@name)} as a podspec (#{e})."
      end

      def validate_podspec
        UI.puts 'Validating podspec'.yellow

        # validator = Validator.new(spec, [])
        # validator.allow_warnings = true
        # validator.use_frameworks = false
        # validator.use_modular_headers = true if validator.respond_to?(:use_modular_headers=)
        # # if validator.respond_to?(:swift_version=)
        # #   validator.swift_version = @swift_version
        # # end
        # validator.skip_import_validation = false
        # validator.skip_tests = false
        # validator.validate
        # unless validator.validated?
        #   raise Informative, "The spec did not pass validation, due to #{validator.failure_reason}."
        # end
        #
        # @swift_version = validator.respond_to?(:used_swift_version) && validator.used_swift_version
      end

    end
  end

  class String
    # colorization
    def colorize(color_code)
      "\e[#{color_code}m#{self}\e[0m"
    end

    def red
      colorize(31)
    end

    def green
      colorize(32)
    end

    def yellow
      colorize(33)
    end

    def blue
      colorize(34)
    end

    def pink
      colorize(35)
    end

    def light_blue
      colorize(36)
    end
  end

end
