#!/bin/bash

# We don't need return codes for "$(command)", only stdout is needed.
# Allow `[[ -n "$(command)" ]]`, `func "$(command)"`, pipes, etc.
# shellcheck disable=SC2312

set -u

echo '- Installing WuKong...'

arch="$(uname -m)"
url="https://github.com/YuXilong/cocoapods-publish/releases/download/v2.2.0/wukong_arm64_1.2.2"
if [ "${arch}" == "x86_64" ]; then
  url="https://github.com/YuXilong/cocoapods-publish/releases/download/v2.2.0/wukong_i386_1.2.2"
fi
path=`pwd`
des="${path}/wukong"
# 从github下载到/usr/local/bin
# curl -L "$url" -o /usr/local/bin/wukong
curl -L "$url" -o $des
# chmod +x /usr/local/bin/wukong
chmod +x $des

# cp "$des" /usr/local/bin

echo '- Installation successful!'

# 更新本地cocoapods插件
./wukong update
./wukong update --pod-plugins
