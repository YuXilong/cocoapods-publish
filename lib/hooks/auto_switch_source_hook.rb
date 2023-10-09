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

  # 获取混淆库
  mixup_libs_map = {}
  context.podfile.dependencies.filter { |de| de.name.start_with?('BT') && de.name.include?('/') }.each do |de|
    result = de.name.split('/')
    mixup_libs_map[result[0]] = result[1]
  end

  # /Users/yuxilong/Library/Caches/CocoaPods
  is_using_framework = using_framework_specs(cache_root).count.positive?
  if (is_using_framework && use_framework) || (!is_using_framework && !use_framework)
    fix_cache(cache_root, project_pods_root, use_framework, mixup_libs_map)
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
  fix_cache(cache_root, project_pods_root, use_framework, mixup_libs_map)
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
def fix_cache(cache_root, project_pods_root, use_framework, mixup_libs_map)
  ignore_names = %w[BTDContext BTAssets]

  Dir.glob("#{cache_root}/Pods/Specs/Release/BT*/*.podspec.json").each do |file|
    json = JSON(File.open(file).read)
    type = json['source']['type']
    tag = json['source']['tag']
    http = json['source']['http']
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

  # mixup_libs_map.each do |k, v|
  #   Dir.glob("#{cache_root}/Pods/Specs/Release/#{k}/*.podspec.json").each do |file|
  #     json = JSON(File.open(file).read)
  #     http = json['source']['http']
  #     next if http.include?("repository/files/#{v}")
  #
  #     name = json['name']
  #     version = json['version']
  #
  #     `rm #{file}`
  #     Dir.glob("#{cache_root}/Pods/Release/#{name}/#{version}*").each { |source_dir| `rm -rf #{source_dir}` }
  #     `rm -rf #{project_pods_root}/#{name}` if Dir.exist?("#{project_pods_root}/#{name}")
  #     puts "已修正#{k}/#{v}-#{version}缓存"
  #   end
  # end

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


# Pod::HooksManager.register('cocoapods-publish', :post_install) do |context, _|
#   project_pods_root = Pod::Config.instance.project_pods_root.to_s
#
#   puts '正在裁剪AgoraSDK...'
#
#   frameworks_to_remove = %w[AgoraAiEchoCancellationExtension AgoraAiNoiseSuppressionExtension AgoraAudioBeautyExtension AgoraClearVisionExtension AgoraDrmLoaderExtension AgoraReplayKitExtension AgoraSpatialAudioExtension]
#
#   frameworks_to_remove = frameworks_to_remove.map { |fw| "#{project_pods_root}/**/#{fw}.xcframework" }
#   frameworks_to_remove.each { |pa|
#     Dir.glob(pa).each { |f|
#       `rm -rf #{f}`
#       process_file(project_pods_root, Pathname(f).basename.to_s)
#       puts "已裁剪#{Pathname(f).basename.to_s}"
#     }
#   }
#
#   puts 'AgoraSDK裁剪完成'
# end

def process_file(pods_root, xc_name)
  Dir.glob("#{pods_root}/**/AgoraRtcEngine_Special_iOS-xcframeworks.sh").each do |file|
    contents = File.open(file).read
    contents.gsub!("install_xcframework \"${PODS_ROOT}/AgoraRtcEngine_Special_iOS/#{xc_name}\" \"AgoraRtcEngine_Special_iOS\" \"framework\" \"ios-arm64_armv7\" \"ios-arm64_x86_64-simulator\"", '')
    File.open(file, 'w') {|f| f.write(contents) }
  end

  Dir.glob("#{pods_root}/**/AgoraRtcEngine_Special_iOS-xcframeworks-output-files.xcfilelist").each do |file|
    contents = File.open(file).read
    contents.gsub!("${PODS_XCFRAMEWORKS_BUILD_DIR}/AgoraRtcEngine_Special_iOS/#{xc_name.split('.')[0]}.framework", '')
    File.open(file, 'w') {|f| f.write(contents) }
  end

  Dir.glob("#{pods_root}/**/AgoraRtcEngine_Special_iOS-xcframeworks-input-files.xcfilelist").each do |file|
    contents = File.open(file).read
    contents.gsub!("${PODS_ROOT}/AgoraRtcEngine_Special_iOS/#{xc_name}", '')
    File.open(file, 'w') {|f| f.write(contents) }
  end

end
