# frozen_string_literal: true
source 'https://rubygems.org'

# 安全版 ActiveSupport 的开发测试环境要求；不改变发布 gem 的 Ruby 兼容声明。
ruby '>= 3.1'

# Specify your gem's dependencies in cocoapods-publish.gemspec
gemspec

group :development do
  gem 'cocoapods', '~> 1.16.2'

  # 保持兼容的版本系列，并禁止解析回已知有漏洞的传递依赖。
  gem 'activesupport', '~> 7.2.3', '>= 7.2.3.1'
  gem 'addressable', '~> 2.9'
  gem 'concurrent-ruby', '~> 1.3', '>= 1.3.7'
  gem 'rexml', '~> 3.3', '>= 3.3.9'

  gem 'bacon'
  gem 'mocha'
  gem 'mocha-on-bacon'
  gem 'prettybacon'

  gem 'plist'
  gem 'rubocop'
  # 旧版 parser 未声明在新版 Ruby 中独立提供的 racc。
  gem 'racc', '~> 1.8'
end
