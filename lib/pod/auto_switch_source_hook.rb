# frozen_string_literal: true

require 'English'
Pod::HooksManager.register('cocoapods-publish', :pre_install) do |context, _|
  cache_root = Pod::Config.instance.cache_root.to_s
  cache_self_root = "#{Dir.home}/.cocoapods"
  project_pods_root = Pod::Config.instance.project_pods_root.to_s
  target_root = "#{cache_root}/Pods"
  source_cache_root = "#{cache_self_root}/Pods_Source"
  framework_cache_root = "#{cache_self_root}/Pods_Framework"
  use_framework = ENV['USE_FRAMEWORK'] == '1'

  # 未启用插件统一走源码
  unless context.podfile.plugins.keys.include?('cocoapods-publish')
    `cp -r #{source_cache_root} #{target_root}` if Dir.exist?(source_cache_root)
    next
  end

  # 移除本地项目内缓存
  Dir.glob("#{project_pods_root}/**/BT*/")
     .each { |path| `rm -rf #{path}` if Dir.exist?(path) }

  # 初始化缓存
  if !Dir.exist?(source_cache_root) && !Dir.exist?(framework_cache_root)
    puts '初始化自定义缓存...'.yellow
    Dir.glob("#{cache_root}/**/BT*/")
       .each { |path| `rm -rf #{path}` if Dir.exist?(path) }

    `cp -r #{target_root} #{source_cache_root}`
    `cp -r #{target_root} #{framework_cache_root}`
    next
  end

  is_using_framework = Dir.glob("#{cache_root}/**/BT*/**/*.framework").count > 5
  next if (is_using_framework && use_framework) || (!is_using_framework && !use_framework)

  # 切换仓库，同步缓存
  puts '正在切换模式，同步缓存...'.yellow
  if use_framework
    `rm -rf #{source_cache_root}`
    `cp -r #{target_root} #{source_cache_root}`
    `rm -rf #{target_root}`
    `cp -r #{framework_cache_root} #{target_root}`
  else
    `rm -rf #{framework_cache_root}`
    `cp -r #{target_root} #{framework_cache_root}`
    `rm -rf #{target_root}`
    `cp -r #{source_cache_root} #{target_root}`
  end

  puts "已切换到#{use_framework ? '二进制' : '源码'}模式".green
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
