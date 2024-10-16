# frozen_string_literal: true
$VERBOSE = nil
require 'pod/command/publish'
require 'cocoapods-publish/pod_utils'
require 'cocoapods-publish/podfile_dsl'
require 'cocoapods-publish/repo_utils'
require 'cocoapods-publish/gitlab_utils'
require 'hooks/auto_switch_source_hook'
require 'hooks/installer'
require 'hooks/version'
require 'hooks/dependency'
require 'hooks/podfile'
