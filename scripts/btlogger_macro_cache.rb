# Created by yuxilong on 2026/10/29.
require 'digest'
require 'fileutils'
require 'open3'
require 'tempfile'

module BTLoggerMacroCache
  def self.prepare(source, cache_root = File.join(Dir.home, 'Library/Caches/cocoapods-publish/SwiftMacros'))
    required = %w[Package.swift Package.resolved scripts/build_macro.sh Sources/BTLoggerMacroPlugin/LoggerMacro.swift]
    required.each { |path| raise "Missing BTLogger macro file: #{path}" unless File.file?(File.join(source, path)) }
    xcode, status = Open3.capture2e('xcodebuild', '-version')
    raise "Unable to select Xcode: #{xcode}" unless status.success?

    build = xcode[/^Build version ([A-Za-z0-9]+)$/, 1]
    raise "Unrecognized Xcode version: #{xcode}" unless build

    architecture, status = Open3.capture2('uname', '-m')
    raise 'BTLogger macro cache requires an Apple Silicon Mac' unless status.success? && architecture.strip == 'arm64'

    files = Dir.chdir(source) {
      Dir['Package.swift', 'Package.resolved', 'scripts/build_macro.sh', 'Sources/**/*',
          'Tests/**/*'].select { |path|
        File.file?(path)
      }.sort
    }
    digest = Digest::SHA256.new.update(File.binread(__FILE__))
    files.each { |path| digest.update(path).update("\0").update(Digest::SHA256.file(File.join(source, path)).digest) }
    directory = File.join(cache_root, 'arm64', 'BTLogger', build, digest.hexdigest)
    executable = File.join(directory, 'BTLoggerMacroPlugin')
    FileUtils.mkdir_p(directory)
    File.open("#{directory}.lock", File::RDWR | File::CREAT, 0600) do |lock|
      lock.flock(File::LOCK_EX)
      if File.executable?(executable)
        puts "[BTLogger] Using cache: #{executable}"
      else
        puts "[BTLogger] Preparing macro: #{directory}"
        # 在固定路径构建，SwiftPM checkout 和产物不会随消费工程路径变化。
        package = File.join(directory, 'package')
        files.each do |path|
          destination = File.join(package, path)
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.cp(File.join(source, path), destination)
        end
        environment = { 'PODS_TARGET_SRCROOT' => package, 'PODS_BUILD_DIR' => File.join(directory, 'output'),
                        'CONFIGURATION' => 'Host', 'EFFECTIVE_PLATFORM_NAME' => '', 'XCODE_VERSION_ACTUAL' => build }
        success = system(environment, '/bin/bash', File.join(package, 'scripts/build_macro.sh'))
        binary = File.join(directory, 'output', 'BTLoggerMacroPlugin', 'Host', build, 'BTLoggerMacroPlugin')
        unless success && File.executable?(binary)
          raise 'BTLogger macro preparation failed. Check the error above, then retry pod install (or Build).'
        end

        copy(binary, executable)
      end
    end
    executable
  end

  def self.copy(source, destination)
    FileUtils.mkdir_p(File.dirname(destination))
    Tempfile.create(['macro-', '.tmp'], File.dirname(destination)) do |file|
      FileUtils.copy_file(source, file.path)
      File.chmod(0755, file.path)
      File.rename(file.path, destination)
    end
  end

  def self.install_for_build(source)
    executable = prepare(source)
    destination = File.join(ENV.fetch('PODS_BUILD_DIR'), 'BTLoggerMacroPlugin',
                            ENV.fetch('CONFIGURATION') + ENV.fetch('EFFECTIVE_PLATFORM_NAME', ''),
                            ENV.fetch('XCODE_VERSION_ACTUAL'), 'BTLoggerMacroPlugin')
    copy(executable, destination)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    BTLoggerMacroCache.install_for_build(ENV.fetch('PODS_TARGET_SRCROOT'))
  rescue StandardError => error
    warn "error: #{error.message}"
    exit 1
  end
end
