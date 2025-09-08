#!/bin/bash

set -u

# 安装Homebrew
install_homebrew() {
    echo '- Installing Homebrew...'
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    user=$(whoami)
    (echo; echo 'eval "$(/opt/homebrew/bin/brew shellenv)"') >> /Users/$whoami/.zprofile
    eval "$(/opt/homebrew/bin/brew shellenv)"
}

# 升级Ruby
upgrade_ruby() {
    echo '- Updating Ruby...'
    brew install ruby
    echo 'export PATH="/opt/homebrew/opt/ruby/bin:$PATH"' >> ~/.zshrc
    export LDFLAGS="-L/opt/homebrew/opt/ruby/lib"
    export CPPFLAGS="-I/opt/homebrew/opt/ruby/include"
    source ~/.zshrc
}

# 安装Cocoapods
install_cocoapods() {
    echo '- Installing Cocoapods...'
    gem sources --remove https://rubygems.org/
    gem sources --add https://gems.ruby-china.com/
    sudo gem update --system
    sudo gem install -n /usr/local/bin/ cocoapods
}

# 安装WuKong
install_wukong() {
    # 安装WuKong
    echo '- Installing WuKong...'
    arch="$(uname -m)"
    url="https://vip.123pan.cn/1832538346/14654662"
    if [ "${arch}" == "x86_64" ]; then
    url="https://vip.123pan.cn/1832538346/14654837"
    fi

    check_dest
    des="$HOME/.local/bin/wukong"
    curl -L "$url" -o $des
    chmod +x $des
    echo '- Installation successful!'

    # 更新本地cocoapods插件
    wukong update
    wukong update --pod-plugins

    pod repo add BaiTuFrameworkPods https://gitlabcode_.v.show/ios_framework/frameworkpods.git
    pod repo update BaiTuFrameworkPods
}

# 更新WuKong
update_wukong() {
    # 安装WuKong
    echo '- Installing WuKong...'
    arch="$(uname -m)"
    url="https://vip.123pan.cn/1832538346/14654662"
    if [ "${arch}" == "x86_64" ]; then
    url="https://vip.123pan.cn/1832538346/14654837"
    fi
    check_dest
    des="$HOME/.local/bin/wukong"
    curl -L "$url" -o $des
    chmod +x $des
    echo '- Installation successful!'
}

check_dest() {
  dest="$HOME/.local/bin/"
  # 判断文件夹是否存在
  if [ ! -d "$dest" ]; then
      mkdir -p "$dest"
      # 将路径写入到 ~/.zshrc 文件中
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
      # 让改动立即生效
      source ~/.zshrc
  fi
}

if ! command -v brew &> /dev/null; then
    install_homebrew
    upgrade_ruby
fi

if ! command -v wukong &> /dev/null; then
    install_wukong
fi

# 提示用户是否继续执行
read -p "已安装wukong，是否更新? (y/n): " choice

# 根据用户的选择决定是否继续执行
case "$choice" in
( y|Y ) 
    update_wukong;;
( n|N ) 
    exit;;
( * ) 
    exit;;
esac
