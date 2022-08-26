# frozen_string_literal: true

Pod::HooksManager.register('auto-switch-source', :pre_install) do |ctx, _|
  project_root = "#{Pod::Config.instance.project_root.to_s}/Pods"
  cache_root = "#{Pod::Config.instance.cache_root.to_s}/Pods"

  Dir.glob("#{cache_root}/**/BT*/")
     .each { |path| `rm -rf #{path}` if Dir.exist?(path) }

  Dir.glob("#{project_root}/**/BT*/")
     .each { |path| `rm -rf #{path}` if Dir.exist?(path) }

  next
end
