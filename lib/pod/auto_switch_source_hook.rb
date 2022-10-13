# frozen_string_literal: true

require 'English'
Pod::HooksManager.register('cocoapods-publish', :pre_install) do |context, _|
  next unless context.podfile.plugins.keys.include?('cocoapods-publish')

  project_root = "#{Pod::Config.instance.project_root}/Pods"
  cache_root = "#{Pod::Config.instance.cache_root}/Pods"

  use_framework = ENV['USE_FRAMEWORK'] == '1'
  if use_framework && !Dir.glob("#{project_root}/**/BT*/**/BT*.framework").empty? && !Dir.glob("#{cache_root}/**/BT*/**/BT*.framework").empty?
    next
  end

  if !use_framework && Dir.glob("#{project_root}/**/BT*/**/BT*.framework").empty? && Dir.glob("#{cache_root}/**/BT*/**/BT*.framework").empty?
    next
  end

  puts '开始清理缓存...'.yellow

  Dir.glob("#{cache_root}/**/BT*/")
     .each { |path| `rm -rf #{path}` if Dir.exist?(path) }

  Dir.glob("#{project_root}/**/BT*/")
     .each { |path| `rm -rf #{path}` if Dir.exist?(path) }

  puts '缓存清理完成'.green
end

Pod::HooksManager.register('cocoapods-publish', :post_install) do |context, _|
  project_root = "#{Pod::Config.instance.project_root}/Pods"
  next if Dir.glob("#{project_root}/**/RCConfig.plist").empty?

  Dir.glob("#{project_root}/**/RCConfig.plist")
     .each do |file|
    command = "/usr/libexec/PlistBuddy -c 'Add :Connection dict' #{file}"
    command += " && /usr/libexec/PlistBuddy -c 'Add :Connection:ForceKeepAlive bool true' #{file} 2>/dev/null"
    `#{command}`
    puts 'RCConfig.plist配置项同步成功！'.green if $CHILD_STATUS.exitstatus.zero?
  end
end

Pod::HooksManager.register('cocoapods-publish', :source_provider) do |context, _|
  sources_manger = Pod::Config.instance.sources_manager
  podfile = Pod::Config.instance.podfile
  next unless podfile

  # 添加源码私有源 && 二进制私有源
  added_sources = %w[https://cdn.cocoapods.org/ https://github.com/volcengine/volcengine-specs.git]
  added_sources << if ENV['USE_FRAMEWORK']
    'http://gitlab.v.show/ios_framework/frameworkpods.git'
                   else
    'http://gitlab.v.show/ios_component/baitupods.git'
                   end
  added_sources.each { |source| context.add_source(sources_manger.source_with_name_or_url(source)) }
end
