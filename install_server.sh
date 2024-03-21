#!/bin/bash

set -u

# 安装WuKongServer
install_wukong_server() {
    # 安装WuKong
    echo '- Installing WuKongServer...'
    url = "https://github.com/YuXilong/cocoapods-publish/releases/download/v2.2.0/wukong-server"
    des="/opt/homebrew/bin/wukong-server"
    curl -L "$url" -o $des
    chmod +x $des
    echo '- Installation successful!'
}

if ! command -v wukong-server &> /dev/null; then
    install_wukong_server
fi
