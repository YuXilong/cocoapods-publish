#!/bin/bash

# WuKong 安装脚本（向后兼容入口）
# 推荐直接使用：brew install yuxilong/tap/wukong

set -e

if ! command -v brew &> /dev/null; then
    echo "正在安装 Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # 配置 Homebrew 环境变量
    if [ -d "/opt/homebrew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -d "/usr/local/Homebrew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

echo "正在通过 Homebrew 安装 wukong..."
brew install yuxilong/tap/wukong

echo "安装完成！请运行 'wukong --version' 验证。"
