require 'colorize'

module Pod
  class Command
    # This is an example of a cocoapods plugin adding a top-level subcommand
    # to the 'pod' command.
    #
    # You can also create subcommands of existing or new commands. Say you
    # wanted to add a subcommand to `list` to show newly deprecated pods,
    # (e.g. `pod list deprecated`), there are a few things that would need
    # to change.
    #
    # - move this file to `lib/pod/command/list/deprecated.rb` and update
    #   the class to exist in the the Pod::Command::List namespace
    # - change this class to extend from `List` instead of `Command`. This
    #   tells the plugin system that it is a subcommand of `list`.
    # - edit `lib/cocoapods_plugins.rb` to require this file
    #
    # @todo Create a PR to add your plugin to CocoaPods/cocoapods.org
    #       in the `plugins.json` file, once your plugin is released.
    #
    class Publish < Command
      self.summary = 'Short description of cocoapods-publish.'

      self.description = <<-DESC
        Longer description of cocoapods-publish.
      DESC

      self.arguments = 'NAME'

      def initialize(argv)
        @name = argv.shift_argument
        super
      end

      def validate!
        super
        help! 'A Pod name is required.' unless @name
      end

      def run
        # UI.puts "Add your implementation for the cocoapods-publish plugin in #{__FILE__}"

        puts "校验pod..."
        command = "pod lib lint BTNetwork.podspec"
        output = `#{command}`.lines.to_a
        if $?.exitstatus != 0
          # UI.puts(output.join(''))
          # puts UI::BuildFailedReport.report(command, output)
          puts "pod 校验不通过！"
          Process.exit
        end

      end
    end
  end
end
