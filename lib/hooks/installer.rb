module Pod
  class Installer

    def install!
      prepare
      resolve_dependencies

      use_framework = ENV['USE_FRAMEWORK']
      check_http_source if use_framework

      download_dependencies
      validate_targets
      clean_sandbox
      if installation_options.skip_pods_project_generation?
        show_skip_pods_project_generation_message
        run_podfile_post_install_hooks
      else
        integrate
      end
      write_lockfiles
      perform_post_install_actions
    end

    private

    # 根据混淆模式动态修改对应地址
    def check_http_source
      analysis_result.specifications.filter { |spec| spec.name.start_with?('BT') }.each do |spec|
        name = spec.attributes_hash['name']
        clean_spec(spec)
        if name.start_with?('Core') || name.eql?(spec.root.name)
          spec.root.source = {
            http: spec.root.source[:http],
            type: spec.root.source[:type],
            headers: spec.root.source[:headers]
          }
          next
        end

        spec.root.source = {
          http: spec.root.source["http_#{name}".to_sym],
          type: spec.root.source[:type],
          headers: spec.root.source[:headers]
        }
      end
    end

    # 检查清理缓存
    def clean_spec(spec)
      cache_root = "#{Config.instance.cache_root}/Pods"
      spec_root = "#{cache_root}/Release/#{spec.root.name}"

      name = spec.attributes_hash['name']
      name = 'BT' if name.start_with?('Core')

      files = Dir.glob("#{spec_root}/#{spec.root.version}*/#{name}*.framework")
      unless files.count.positive?
        Dir.glob("#{spec_root}/#{spec.root.version}*/*.framework").each do |file|
          `rm -rf #{Pathname(file).parent}`
        end
      end
    end

  end
end
