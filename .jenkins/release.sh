#!/usr/bin/env bash
set -euo pipefail

GEM_NAME=cocoapods-publish
VERSION_FILE=lib/cocoapods-publish.rb
VERSION_BUMP="${VERSION_BUMP:-patch}"
DRY_RUN="${DRY_RUN:-true}"
case "$VERSION_BUMP" in patch|minor|major) ;; *) exit 1 ;; esac
case "$DRY_RUN" in true|false) ;; *) exit 1 ;; esac
BUCKET=YuXilong/cocoapods-publish
BUCKET_TAG=v2.2.0
REPO="YuXilong/$GEM_NAME"
mkdir -p .jenkins-output/tmp
export TMPDIR="$PWD/.jenkins-output/tmp"
export COVERALLS_NO_POST=1
bundle check || GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.version GIT_CONFIG_VALUE_0=HTTP/1.1 bundle install --retry 2
# 保留原 Actions 的非阻断测试策略；失败仍记录在 Jenkins 日志中。
if ! bundle exec rake specs; then
  echo 'WARNING: 现有 specs 基线未通过，沿用原发布流程继续构建。' >&2
fi
export GEM_NAME VERSION_FILE VERSION_BUMP
ruby <<'RUBY'
path = ENV.fetch('VERSION_FILE')
content = File.read(path)
current = content[/VERSION = ['"](\d+\.\d+\.\d+)['"]\.freeze/, 1]
abort 'Missing VERSION constant' unless current
major, minor, patch = current.split('.').map(&:to_i)
version = case ENV.fetch('VERSION_BUMP')
          when 'major' then "#{major + 1}.0.0"
          when 'minor' then "#{major}.#{minor + 1}.0"
          when 'patch' then "#{major}.#{minor}.#{patch + 1}"
          end
File.write(path, content.sub(/VERSION = ['"][^'"]+['"]\.freeze/, "VERSION = '#{version}'.freeze"))
lock = File.read('Gemfile.lock')
pattern = /^(\s{4}#{Regexp.escape(ENV.fetch('GEM_NAME'))} \()[^)]+(\))$/
abort 'Missing path gem version in Gemfile.lock' unless lock.sub!(pattern) { "#{$1}#{version}#{$2}" }
File.write('Gemfile.lock', lock)
File.write('.jenkins-output/version', version)
puts "#{current} -> #{version}"
RUBY
VERSION=$(cat .jenkins-output/version)
GEM_FILE=".jenkins-output/${GEM_NAME}-${VERSION}.gem"
gem build "${GEM_NAME}.gemspec" --output "$GEM_FILE"
test -s "$GEM_FILE"
if [[ "$DRY_RUN" == true ]]; then
  echo '验证构建完成；未提交版本、上传产物或触发工具链更新。'
  exit 0
fi

: "${GH_TOKEN:?Jenkins github-release credential required}"
git config credential.helper '!gh auth git-credential'
git config user.name 'jenkins-release'
git config user.email 'jenkins-release@users.noreply.github.com'
git fetch origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || {
  echo 'main 已更新，请重新运行发布。' >&2; exit 1;
}
git add "$VERSION_FILE" Gemfile.lock
git commit -m "chore: bump version to ${VERSION} [skip ci]"
git push origin HEAD:main
git log -10 --pretty=format:'- %s' --no-merges > .jenkins-output/release-notes.md
gh release create "v$VERSION" "$GEM_FILE" --repo "$REPO" \
  --target "$(git rev-parse HEAD)" --title "$GEM_NAME v$VERSION" \
  --notes-file .jenkins-output/release-notes.md --prerelease
gh release upload "$BUCKET_TAG" "$GEM_FILE" --repo "$BUCKET" --clobber
gh release view "$BUCKET_TAG" --repo "$BUCKET" --json assets \
  --jq ".assets[] | select(.name | test(\"^${GEM_NAME}-[0-9]+[.][0-9]+[.][0-9]+[.]gem$\")) | .name" \
  > .jenkins-output/assets
while IFS= read -r asset; do
  [[ "$asset" == "${GEM_NAME}-${VERSION}.gem" ]] && continue
  gh release delete-asset "$BUCKET_TAG" "$asset" --repo "$BUCKET" --yes
done < .jenkins-output/assets
