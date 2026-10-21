require 'fileutils'
require 'tmpdir'
require 'open3'

# 用假的构建命令验证版本进位和 DRY_RUN 的发布边界，不访问远端。
script = File.expand_path('release.sh', __dir__)
root = File.expand_path('..', __dir__)
FileUtils.mkdir_p(File.join(root, '.tmp'))
products = File.basename(root) == 'WuKong' ? %w[wukong wukong-server] : [File.basename(root)]
products.each do |product|
  { 'patch' => '9.9.10', 'minor' => '9.10.0', 'major' => '10.0.0' }.each do |bump, expected|
    Dir.mktmpdir('release-test-', File.join(root, '.tmp')) do |dir|
      if product.start_with?('wukong')
        FileUtils.mkdir_p(File.join(dir, product))
        File.write(File.join(dir, product, 'Cargo.toml'), "[package]\nversion = \"9.9.9\"\n")
      else
        FileUtils.mkdir_p(File.join(dir, 'lib'))
        name = product == 'cocoapods-packager' ? 'cocoapods_packager' : product
        File.write(File.join(dir, 'lib', "#{name}.rb"), "VERSION = '9.9.9'.freeze\n")
        File.write(File.join(dir, 'Gemfile.lock'), "    #{product} (9.9.9)\n")
      end
      wrapper = <<~'BASH'
        set -euo pipefail
        git() { echo 'Unexpected git operation in DRY_RUN' >&2; exit 90; }
        gh() { echo 'Unexpected GitHub operation in DRY_RUN' >&2; exit 91; }
        rustup() { :; }
        bundle() { [[ "${FAIL_SPECS:-false}" != true || "$*" != "exec rake specs" ]]; }
        cargo() {
          mkdir -p target/aarch64-apple-darwin/release target/x86_64-apple-darwin/release wukong-server/target/aarch64-apple-darwin/release
          printf binary > target/aarch64-apple-darwin/release/wukong
          printf binary > target/x86_64-apple-darwin/release/wukong
          printf binary > wukong-server/target/aarch64-apple-darwin/release/wukong-server
        }
        gem() { for arg; do :; done; printf gem > "$arg"; }
        export -f git gh rustup cargo bundle gem
        bash "$RELEASE_SCRIPT"
      BASH
      FileUtils.rm_rf(File.join(dir, '.jenkins-output'))
      _, failed = Open3.capture2e(
        { 'VERSION_BUMP' => bump, 'DRY_RUN' => 'true', 'RELEASE_SCRIPT' => script, 'FAIL_SPECS' => 'true' },
        'bash', '-c', wrapper, chdir: dir
      )
      abort 'Released despite failing specs' if failed.success?
      abort 'Changed version after failing specs' if File.exist?(File.join(dir, '.jenkins-output/version'))
      # 重新执行成功分支以验证原有版本进位和产物检查。
      output, status = Open3.capture2e(
        { 'VERSION_BUMP' => bump, 'DRY_RUN' => 'true', 'RELEASE_SCRIPT' => script },
        'bash', '-c', wrapper, chdir: dir
      )
      abort output unless status.success?
      actual = File.read(File.join(dir, '.jenkins-output/version')).strip
      abort "#{product} #{bump}: #{actual} != #{expected}" unless actual == expected
      artifacts = Dir[File.join(dir, '.jenkins-output', "#{product}_*"), File.join(dir, '.jenkins-output', '*.gem')]
      abort "Missing artifacts for #{product}" unless artifacts.length == (product == 'wukong' ? 2 : 1)
    end
  end
end
%w[VERSION_BUMP DRY_RUN PRODUCT].each do |key|
  next if key == 'PRODUCT' && !products.first.start_with?('wukong')
  _, status = Open3.capture2e({ key => 'invalid' }, 'bash', script, chdir: root)
  abort "Accepted invalid #{key}" if status.success?
end
puts "Release checks passed: #{products.join(', ')}"
