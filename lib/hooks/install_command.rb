# frozen_string_literal: true

module Pod
  class Command
    # Adds the opt-in --precheck flag to the native pod install command.
    class Install
      class << self
        alias origin_options_without_precheck options

        def options
          [
            ['--precheck', 'Check all direct Podfile dependencies before resolving']
          ].concat(origin_options_without_precheck)
        end
      end

      alias origin_initialize_without_precheck initialize
      alias origin_installer_for_config_without_precheck installer_for_config

      def initialize(argv)
        origin_initialize_without_precheck(argv)
        @precheck_dependencies = argv.flag?('precheck', false)
      end

      private

      def installer_for_config
        installer = origin_installer_for_config_without_precheck
        installer.precheck_dependencies = @precheck_dependencies
        installer
      end
    end
  end
end
