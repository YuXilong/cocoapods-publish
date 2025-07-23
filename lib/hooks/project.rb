# frozen_string_literal: true
require 'xcodeproj'
require 'active_support/core_ext/string/inflections'

module Pod
  # The Pods project.
  #
  # Model class which provides helpers for working with the Pods project
  # through the installation process.
  #
  class Project < Xcodeproj::Project
    alias origin_add_podfile add_podfile
    # frozen_string_literal: true
    def add_podfile(podfile_path)
      origin_add_podfile(podfile_path)
      local_podfile_path = "#{podfile_path}.local"
      origin_add_podfile(local_podfile_path) if File.exist?(local_podfile_path)
    end
  end
end

