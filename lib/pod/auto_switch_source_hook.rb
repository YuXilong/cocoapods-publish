# frozen_string_literal: true

require 'English'
Pod::HooksManager.register('cocoapods-publish', :pre_install) do |context, _|
  cache_root = Pod::Config.instance.cache_root.to_s
  project_pods_root = Pod::Config.instance.project_pods_root.to_s
  target_root = "#{cache_root}/Pods"
  source_cache_root = "#{cache_root}/Pods_Source"
  framework_cache_root = "#{cache_root}/Pods_Framework"
  use_framework = ENV['USE_FRAMEWORK'] == '1'

  # 未启用插件统一走源码
  unless context.podfile.plugins.keys.include?('cocoapods-publish')
    if Dir.exist?(source_cache_root)
      `mv #{target_root} #{framework_cache_root}`
      `mv #{source_cache_root} #{target_root}`
    end
    next
  end

  if !Dir.exist?(source_cache_root) && !Dir.exist?(framework_cache_root)
    Dir.glob("#{cache_root}/**/BT*/")
       .each { |path| `rm -rf #{path}` if Dir.exist?(path) }
    Dir.glob("#{project_pods_root}/**/BT*/")
       .each { |path| `rm -rf #{path}` if Dir.exist?(path) }
    if use_framework
      `cp -r #{target_root} #{source_cache_root}`
    else
      `cp -r #{target_root} #{framework_cache_root}`
    end
    next
  end

  next if !Dir.exist?(framework_cache_root) && use_framework
  next if !Dir.exist?(source_cache_root) && !use_framework

  if use_framework
    `mv #{target_root} #{source_cache_root}`
    `mv #{framework_cache_root} #{target_root}`
  else
    `mv #{target_root} #{framework_cache_root}`
    `mv #{source_cache_root} #{target_root}`
  end

  Dir.glob("#{project_pods_root}/BT*").each { |path| `rm -rf #{path}` }


  puts '已切换源地址'.green
end

Pod::HooksManager.register('cocoapods-publish', :source_provider) do |context, _|
  sources_manger = Pod::Config.instance.sources_manager
  podfile = Pod::Config.instance.podfile
  next unless podfile

  use_framework = ENV['USE_FRAMEWORK'] == '1'

  # 添加源码私有源 && 二进制私有源
  added_sources = %w[https://cdn.cocoapods.org/ https://github.com/volcengine/volcengine-specs.git]
  added_sources << if use_framework
    'http://gitlab.v.show/ios_framework/frameworkpods.git'
                   else
    'http://gitlab.v.show/ios_component/baitupods.git'
                   end
  added_sources.each { |source| context.add_source(sources_manger.source_with_name_or_url(source)) }
end
