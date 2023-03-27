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

  # 自动指定单个库开启源码模式
  context.podfile.check_envs

  # 初始化缓存
  if !Dir.exist?(source_cache_root) && !Dir.exist?(framework_cache_root)
    puts '初始化自定义缓存...'.yellow
    Dir.glob("#{cache_root}/**/BT*/")
       .each { |path| `rm -rf #{path}` if Dir.exist?(path) }

    # 移除本地项目内缓存
    Dir.glob("#{project_pods_root}/**/BT*/")
       .each { |path| `rm -rf #{path}` if Dir.exist?(path) }

    `cp -r #{target_root} #{source_cache_root}`
    `cp -r #{target_root} #{framework_cache_root}`
    next
  end

  # /Users/yuxilong/Library/Caches/CocoaPods
  is_using_framework = using_framework_specs(cache_root).count.positive?
  if (is_using_framework && use_framework) || (!is_using_framework && !use_framework)
    fix_cache(cache_root, project_pods_root, use_framework)
    next
  end

  # 移除本地项目内缓存
  Dir.glob("#{project_pods_root}/**/BT*/")
     .each { |path| `rm -rf #{path}` if Dir.exist?(path) }

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
  fix_cache(cache_root, project_pods_root, use_framework)
  puts "已切换到#{use_framework ? '二进制' : '源码'}模式".green
end

def using_framework_specs(cache_root)
  Dir.glob("#{cache_root}/Pods/Specs/Release/BT*/*.podspec.json").filter do |file|
    json = JSON(File.open(file).read)
    type = json['source']['type']
    type == 'zip'
  end
end

# 修正本地缓存
def fix_cache(cache_root, project_pods_root, use_framework)
  ignore_names = %w[BTDContext BTAssets]

  Dir.glob("#{cache_root}/Pods/Specs/Release/BT*/*.podspec.json").each do |file|
    json = JSON(File.open(file).read)
    type = json['source']['type']
    tag = json['source']['tag']
    name = json['name']
    version = json['version']
    if use_framework
      next if type == 'zip' || ignore_names.include?(name)

      `rm #{file}`
      Dir.glob("#{cache_root}/Pods/Release/#{name}/#{version}*").each { |source_dir| `rm -rf #{source_dir}` }
      `rm -rf #{project_pods_root}/#{name}` if Dir.exist?("#{project_pods_root}/#{name}")
      puts "已修正#{name}-#{version}缓存"
    else
      next if tag == version

      `rm #{file}`
      Dir.glob("#{cache_root}/Pods/Release/#{name}/#{version}*").each { |source_dir| `rm -rf #{source_dir}` }
      Dir.glob("#{project_pods_root}/#{name}").each { |source_dir| `rm -rf #{source_dir}` }
      puts "已修正#{name}-#{version}缓存"
    end

  end

  Dir.glob("#{cache_root}/Pods/Specs/Release/BT*").each do |file|
    Dir.rmdir(file) if Dir.empty?(file)
  end

  Dir.glob("#{cache_root}/Pods/Release/BT*").each do |file|
    Dir.rmdir(file) if Dir.empty?(file)
  end

  Dir.glob("#{cache_root}/Pods/**/BT*/**/BT*.framework").each { |f| `rm -rf #{f}` } unless use_framework
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
