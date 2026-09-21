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
    MIN_IOS_DEPLOYMENT_TARGET = '15.1'.freeze

    def self.ios_deployment_target(value)
      value = value.to_s
      return MIN_IOS_DEPLOYMENT_TARGET unless Version.correct?(value)

      [Version.new(value), Version.new(MIN_IOS_DEPLOYMENT_TARGET)].max.to_s
    end

    # 必须先于依赖解析执行；post_install 只能调整生成工程，无法修复平台解析冲突。
    def normalize_ios_deployment_targets!
      target_definitions.each_value do |target|
        platform = target.platform
        next unless platform && platform.name == :ios

        target.set_platform(:ios, Podfile.ios_deployment_target(platform.deployment_target))
      end
    end

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
            if target.platform_name == :ios
              config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = Podfile.ios_deployment_target(
                config.build_settings['IPHONEOS_DEPLOYMENT_TARGET']
              )
            end
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