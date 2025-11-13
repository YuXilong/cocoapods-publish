module Pod
  # The Podfile is a specification that describes the dependencies of the
  # targets of an Xcode project.
  #
  # It supports its own DSL and is stored in a file named `Podfile`.
  #
  # The Podfile creates a hierarchy of target definitions that store the
  # information necessary to generate the CocoaPods libraries.
  #
  class Podfile
    alias origin_post_install! post_install!
    # Calls the post install callback if defined.
    #
    # @param  [Pod::Installer] installer
    #         the installer that is performing the installation.
    #
    # @return [Boolean] whether a post install callback was specified and it was
    #         called.
    #
    def post_install!(installer)

      # 添加默认的参数
      installer.generated_projects.each do |project|
        project.targets.each do |target|
          target.build_configurations.each do |config|
            config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
            if target.name.end_with?('Unit-Tests')
              config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
              config.build_settings['DEVELOPMENT_TEAM'] = '33XFRZV3M7'
              config.build_settings['CODE_SIGN_IDENTITY'] = 'Apple Development'
              config.build_settings['CODE_SIGN_IDENTITY[sdk=iphoneos*]'] = 'iPhone Developer'
            else
              config.build_settings['CODE_SIGN_IDENTITY'] = ''
            end
          end
        end
      end

      origin_post_install!(installer)
    end
  end

end