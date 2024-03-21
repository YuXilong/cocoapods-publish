#!/bin/bash

set -u

# 安装WuKongServer
install_wukong_server() {
    # 安装WuKong
    echo '- Installing wukong-server...'
    url="https://github.com/YuXilong/cocoapods-publish/releases/download/v2.2.0/wukong-server"
    des="/opt/homebrew/bin/wukong-server"
    curl -L "$url" -o $des
    chmod +x $des
    echo '- Installation successful!'
}

if ! command -v wukong-server &> /dev/null; then
    install_wukong_server
fi

# 提示用户是否继续执行
read -p "已安装wukong-server，是否更新? (y/n): " choice

# 根据用户的选择决定是否继续执行
case "$choice" in
  y|Y ) install_wukong_server;;
  n|N ) exit;;
  * ) exit;;
esac
