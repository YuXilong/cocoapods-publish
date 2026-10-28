require 'bundler/gem_tasks'

def specs(dir)
  FileList["spec/#{dir}/*_spec.rb"].shuffle.join(' ')
end

desc 'Runs all the specs'
task :specs do
  sh "bundle exec bacon #{specs('**')}"
  ruby 'test/reer_macro_cache_test.rb'
end

task :default => :specs

