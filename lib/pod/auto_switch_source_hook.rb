# frozen_string_literal: true

Pod::HooksManager.register('cocoapods-publish', :pre_install) do |ctx, _|
  next unless ctx.podfile.plugins.keys.include?('cocoapods-publish')

  puts '开始清理缓存...'.yellow

  project_root = "#{Pod::Config.instance.project_root}/Pods"
  cache_root = "#{Pod::Config.instance.cache_root}/Pods"

  Dir.glob("#{cache_root}/**/BT*/")
     .each { |path| `rm -rf #{path}` if Dir.exist?(path) }

  Dir.glob("#{project_root}/**/BT*/")
     .each { |path| `rm -rf #{path}` if Dir.exist?(path) }

  puts '缓存清理完成'.green
  next
end
