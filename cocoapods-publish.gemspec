# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'cocoapods-publish.rb'

Gem::Specification.new do |spec|
  spec.name          = 'cocoapods-publish'
  spec.version       = CocoapodsPublish::VERSION
  spec.authors       = ['yuxilong']
  spec.email         = ['305758560@qq.com']
  spec.description   = %q{A short description of cocoapods-publish.}
  spec.summary       = %q{A longer description of cocoapods-publish.}
  spec.homepage      = 'https://github.com/EXAMPLE/cocoapods-publish'
  spec.license       = 'MIT'

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '~> 2.2.29'
  spec.add_development_dependency 'rake'
end
