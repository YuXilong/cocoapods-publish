# Created by yuxilong on 2026/10/28.
require 'fileutils'
require 'open3'
require 'tempfile'

# 同一份 helper 用于 pod install 和生成工程的构建阶段；不依赖 CocoaPods/RubyGems。
module ReerMacroCache
  def self.prepare(script, version, cache_root = File.join(Dir.home, 'Library/Caches/cocoapods-publish/SwiftMacros'))
    raise 'Invalid ReerCodable version' unless version.match?(/\A\d+(?:\.\d+)*\z/)

    xcode, status = Open3.capture2e('xcodebuild', '-version')
    raise "Unable to select Xcode: #{xcode}" unless status.success?
    build = xcode[/^Build version ([A-Za-z0-9]+)$/, 1]
    raise "Unrecognized Xcode version: #{xcode}" unless build
    architecture, status = Open3.capture2('uname', '-m')
    raise 'ReerCodable macros require an Apple Silicon Mac' unless status.success? && architecture.strip == 'arm64'

    root = File.join(cache_root, 'arm64')
    directory = File.join(root, 'ReerCodable', version, build)
    executable = File.join(directory, 'ReerCodableMacros')
    FileUtils.mkdir_p(directory)
    File.open("#{directory}.lock", File::RDWR | File::CREAT, 0600) do |lock|
      lock.flock(File::LOCK_EX)
      puts "[ReerCodable] #{File.executable?(executable) ? 'Using cache' : 'Preparing macro'}: #{directory}"
      # 原规格检查 Xcode 白名单、下载校验和与 manifest，成功后才原子发布可执行文件。
      success = system({ 'PODS_BUILD_DIR' => root, 'XCODE_VERSION_ACTUAL' => build }, '/bin/bash', script)
      unless success && File.executable?(executable)
        raise 'ReerCodable macro preparation failed. Check the download error above, then retry pod install (or Build).'
      end
    end
    executable
  end

  def self.install_for_build(script, version)
    executable = prepare(script, version)
    directory = File.join(ENV.fetch('PODS_BUILD_DIR'), 'ReerCodable', version, ENV.fetch('XCODE_VERSION_ACTUAL'))
    FileUtils.mkdir_p(directory)
    Tempfile.create(['ReerCodableMacros-', '.tmp'], directory) do |file|
      FileUtils.copy_file(executable, file.path)
      File.chmod(0755, file.path)
      File.rename(file.path, File.join(directory, 'ReerCodableMacros'))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    ReerMacroCache.install_for_build(File.join(__dir__, 'download.sh'), ARGV.fetch(0))
  rescue StandardError => error
    warn "error: #{error.message}"
    exit 1
  end
end
