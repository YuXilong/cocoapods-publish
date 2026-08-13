# frozen_string_literal: true

require 'cgi'
require 'json'
require 'net/http'
require 'open3'
require 'optparse'
require 'fileutils'
require 'rexml/document'
require 'rexml/xpath'
require 'time'
require 'uri'
require 'yaml'

module PcmRebuildOnce
  COMPONENT_PATTERN = /\ABT[A-Za-z0-9_]+\z/.freeze

  class Error < StandardError; end

  class CommandRunner
    def capture(*command)
      output, error_output, status = Open3.capture3(*command)
      return output if status.success?

      raise Error, "命令执行失败：#{command.join(' ')}\n#{error_output}"
    end

    def each_output_line(*command, &block)
      Open3.popen3(*command) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        error_reader = Thread.new { stderr.read }
        stdout.each_line(&block)
        error_output = error_reader.value
        next if wait_thread.value.success?

        raise Error, "命令执行失败：#{command.join(' ')}\n#{error_output}"
      end
    end
  end

  class VersionInfo
    SOURCE_VERSION_PATTERN = /\A\d+(?:\.\d+)*(?:\.b\d+)?/.freeze

    attr_reader :artifact_version, :source_version

    def self.parse(artifact_version)
      source_version = artifact_version.to_s[SOURCE_VERSION_PATTERN]
      raise Error, "无法从版本号 #{artifact_version.inspect} 提取源码版本" unless source_version

      new(artifact_version, source_version)
    end

    def initialize(artifact_version, source_version)
      @artifact_version = artifact_version
      @source_version = source_version
    end

    def beta?
      source_version.match?(/\.b\d+\z/)
    end

    def mixup?
      artifact_version.match?(/(?:\A|\.)[A-Z0-9]+-(?:SCF|CF|SC|C)(?:\.|\z)/)
    end

    def bt_assets_branch
      version_without_swift = artifact_version.sub(/\.swift-[\d.]+\z/, '')
      suffix = version_without_swift.delete_prefix(source_version).sub(/\A\./, '')
      return 'main' if suffix.empty?
      return 'Vone' if suffix.casecmp('VONE').zero?

      suffix
    end
  end

  class LockfileParser
    POD_ENTRY_PATTERN = /\A {2}-\s+["']?([^\s("']+)\s+\(([^)]+)\)/.freeze

    def self.parse(path)
      raise Error, "找不到 Podfile.lock：#{path}" unless File.file?(path)

      versions = {}
      reading_pods = false
      File.foreach(path) do |line|
        if line.chomp == 'PODS:'
          reading_pods = true
          next
        end

        # CocoaPods may serialize :path: as Symbol outside PODS; parsing only
        # this text section avoids permitting arbitrary YAML object classes.
        break if reading_pods && line.match?(/\A\S/)
        next unless reading_pods

        match = line.match(POD_ENTRY_PATTERN)
        next unless match

        component = match[1].split('/').first
        versions[component] = match[2] if component.start_with?('BT')
      end
      versions
    end
  end

  class PodfileUpdater
    DECLARATION_PATTERN = /
      (?<call>\bpod(?:\s+|\())
      (?<name_quote>['"])
      (?<name>BT[A-Za-z0-9_]+(?:\/[^'"]+)?)
      \k<name_quote>
      (?<separator>\s*,\s*)
      (?<version_quote>['"])
      (?<version>[^'"]+)
      \k<version_quote>
    /x.freeze

    def self.update(path, versions)
      raise Error, "找不到 Podfile：#{path}" unless File.file?(path)

      changes = {}
      updated_lines = File.readlines(path).map do |line|
        next line if line.lstrip.start_with?('#')

        line.gsub(DECLARATION_PATTERN) do |declaration|
          match = Regexp.last_match
          component = match[:name].split('/').first
          new_version = versions[component]
          next declaration if new_version.to_s.empty? || new_version == match[:version]

          changes[component] ||= [match[:version], new_version]
          "#{match[:call]}#{match[:name_quote]}#{match[:name]}#{match[:name_quote]}" \
            "#{match[:separator]}#{match[:version_quote]}#{new_version}" \
            "#{match[:version_quote]}"
        end
      end
      write(path, updated_lines.join) unless changes.empty?
      changes
    end

    def self.write(path, content)
      mode = File.stat(path).mode & 0o777
      temporary_path = "#{path}.tmp-#{Process.pid}"
      File.open(temporary_path, 'w', mode) { |file| file.write(content) }
      File.rename(temporary_path, path)
    ensure
      File.unlink(temporary_path) if temporary_path && File.exist?(temporary_path)
    end

    private_class_method :write
  end

  class BranchOverrides
    def self.load(path)
      return {} if path.to_s.empty?
      raise Error, "找不到分支覆盖文件：#{path}" unless File.file?(path)

      document = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      return {} if document.nil?

      raise Error, '分支覆盖文件必须是“组件名: 分支名”的 YAML 映射' unless document.is_a?(Hash)

      document.each_with_object({}) do |(component, branch), result|
        raise Error, "非法分支覆盖项：#{component.inspect} => #{branch.inspect}" unless component.to_s.match?(COMPONENT_PATTERN)

        normalized_branch = branch.to_s.strip
        next if normalized_branch.empty?

        result[component.to_s] = normalized_branch
      end
    rescue Psych::Exception => e
      raise Error, "分支覆盖文件解析失败：#{e.message}"
    end
  end

  class BranchPlanWriter
    def self.write(path, tasks)
      expanded_path = File.expand_path(path)
      FileUtils.mkdir_p(File.dirname(expanded_path))
      File.open(expanded_path, 'w', 0o600) do |file|
        file.puts('# PCM 组件发布分支；空值需要确认后手动填写')
        file.puts('# 填写完成后再次执行脚本；脚本会自动读取本文件')
        tasks.each { |task| write_task(file, task) }
      end
      expanded_path
    end

    def self.write_task(file, task)
      details = [
        task[:artifact_version],
        "source=#{task[:source_version]}",
        task[:job]
      ].compact.join(' | ')
      file.puts
      file.puts("# #{details}")
      if task[:status] == 'ready'
        file.puts("#{task.fetch(:component)}: #{task.fetch(:branch).to_json}")
      else
        error = task.fetch(:error).gsub(/\s+/, ' ')
        file.puts("# TODO: #{error}")
        file.puts("#{task.fetch(:component)}:")
      end
    end

    private_class_method :write_task
  end

  class PcmScanner
    def initialize(project_root, dwarf_scanner:)
      @project_root = File.expand_path(project_root)
      @dwarf_scanner = dwarf_scanner
    end

    def scan(versions)
      versions.filter_map do |component, artifact_version|
        affected_binaries = []
        pcm_count = framework_binaries(component).sum do |binary|
          count = @dwarf_scanner.count(binary)
          affected_binaries << binary if count.positive?
          count
        end
        next if pcm_count.zero?

        {
          component: component,
          artifact_version: artifact_version,
          pcm_count: pcm_count,
          binaries: affected_binaries
        }
      end
    end

    private

    def framework_binaries(component)
      pattern = File.join(@project_root, 'Pods', component, '**', '*.framework')
      Dir.glob(pattern).filter_map do |framework|
        binary = File.join(framework, File.basename(framework, '.framework'))
        binary if File.file?(binary)
      end.uniq.sort
    end
  end

  class DwarfScanner
    def initialize(runner: CommandRunner.new)
      @runner = runner
    end

    def count(binary)
      pcm_count = 0
      @runner.each_output_line('xcrun', 'dwarfdump', '--debug-info', binary) do |line|
        pcm_count += 1 if line.include?('DW_AT_GNU_dwo_name') && line.include?('.pcm')
      end
      pcm_count
    end
  end

  class GitLabRepository
    def initialize(component, client:)
      @component = component
      @client = client
    end

    def find_update_commit(source_version)
      expected_subject = "[Update] (#{source_version})"
      page = 1
      loop do
        commits, next_page = @client.commits(@component, page: page)
        match = commits.find { |commit| commit['title'] == expected_subject }
        match ||= commits.find do |commit|
          title = commit['title'].to_s
          title.start_with?("[Update] (#{source_version}.swift-") &&
            title.end_with?(')')
        end
        return match.fetch('id') if match

        break if next_page.to_s.empty?

        page = next_page.to_i
      end

      raise Error, "#{@component} 找不到提交 #{expected_subject}"
    end

    def branches_containing(commit)
      @client.commit_branches(@component, commit).uniq.sort
    end

    def head_commit(branch)
      @client.branch_head(@component, branch)
    end
  end

  class GitLabClient
    RESPONSE = Struct.new(:code, :body, :headers, keyword_init: true)
    PROJECT_NAMESPACE = 'ios_component'

    def initialize(base_url:, token:, requester: nil)
      @base_uri = URI(base_url)
      unless %w[http https].include?(@base_uri.scheme) && @base_uri.host
        raise Error, "非法 GitLab API 地址：#{base_url.inspect}"
      end
      raise Error, '必须设置 GIT_LAB_TOKEN' if token.to_s.empty?

      @token = token
      @requester = requester || method(:perform_request)
    end

    def commits(component, page:)
      get_json(
        "#{project_path(component)}/repository/commits",
        'all' => 'true',
        'per_page' => '100',
        'page' => page.to_s
      )
    end

    def commit_branches(component, commit)
      page = 1
      branches = []
      loop do
        references, next_page = get_json(
          "#{project_path(component)}/repository/commits/#{escape(commit)}/refs",
          'type' => 'branch',
          'per_page' => '100',
          'page' => page.to_s
        )
        branches.concat(references.map { |reference| reference.fetch('name') })
        break if next_page.to_s.empty?

        page = next_page.to_i
      end
      branches
    end

    def branch_head(component, branch)
      data, = get_json(
        "#{project_path(component)}/repository/branches/#{escape(branch)}"
      )
      data.fetch('commit').fetch('id')
    rescue KeyError => e
      raise Error, "#{component} 分支 #{branch} 响应缺少字段：#{e.message}"
    end

    private

    def project_path(component)
      project = "#{PROJECT_NAMESPACE}/#{component}"
      "/projects/#{escape(project)}"
    end

    def escape(value)
      CGI.escape(value.to_s).gsub('+', '%20')
    end

    def get_json(path, query = {})
      uri = URI.join(normalized_base_url, path.sub(%r{\A/}, ''))
      uri.query = URI.encode_www_form(query) unless query.empty?
      ensure_same_origin!(uri)
      request = Net::HTTP::Get.new(uri.request_uri)
      request['PRIVATE-TOKEN'] = @token
      response = normalize_response(@requester.call(uri, request))
      raise Error, "GitLab API 请求失败，HTTP #{response.code}" unless response.code == 200

      [JSON.parse(response.body), response.headers['x-next-page']]
    rescue JSON::ParserError => e
      raise Error, "GitLab API 响应解析失败：#{e.message}"
    end

    def normalized_base_url
      base_url = @base_uri.to_s
      base_url.end_with?('/') ? base_url : "#{base_url}/"
    end

    def ensure_same_origin!(uri)
      return if uri.scheme == @base_uri.scheme &&
                uri.host == @base_uri.host &&
                uri.port == @base_uri.port

      raise Error, "拒绝向 GitLab 以外的地址发送凭据：#{uri}"
    end

    def normalize_response(response)
      headers = {}
      response.each_header { |name, value| headers[name.downcase] = value }
      RESPONSE.new(
        code: response.code.to_i,
        body: response.body.to_s,
        headers: headers
      )
    end

    def perform_request(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 30
      http.request(request)
    end
  end

  module RepositoryName
    ALIASES = {
      'BTSearchSwift' => 'BTSearchRecommendSwift'
    }.freeze

    def self.for(component)
      ALIASES.fetch(component, component)
    end
  end

  class GitLabRepositoryProvider
    def initialize(client:)
      @client = client
    end

    def repository(component)
      validate_component!(component)
      repository_name = RepositoryName.for(component)
      GitLabRepository.new(repository_name, client: @client)
    end

    private

    def validate_component!(component)
      return if component.match?(COMPONENT_PATTERN)

      raise Error, "非法组件名：#{component.inspect}"
    end
  end

  class BranchResolver
    RELEASE_BRANCH_PREFERENCE = %w[main master develop].freeze

    def initialize(repository_provider:)
      @repository_provider = repository_provider
    end

    def resolve(component:, artifact_version:, override: nil)
      return override unless override.to_s.empty?

      version = VersionInfo.parse(artifact_version)
      return version.bt_assets_branch if component == 'BTAssets'

      repository = @repository_provider.repository(component)
      commit = repository.find_update_commit(version.source_version)
      branches = repository.branches_containing(commit)
      return beta_branch(repository, commit, branches, component, version) if version.beta?

      RELEASE_BRANCH_PREFERENCE.each do |preferred|
        return preferred if branches.include?(preferred)
      end
      return branches.first if branches.one?

      raise Error, "#{component} #{version.source_version} 无法唯一确定发布分支：#{branches.join(', ')}"
    end

    private

    def beta_branch(repository, commit, branches, component, version)
      head_branches = branches.select { |branch| repository.head_commit(branch) == commit }
      return head_branches.first if head_branches.one?

      version_branches = branches.select { |branch| branch.include?(version.source_version) }
      return version_branches.first if version_branches.one?

      raise Error, "#{component} #{version.source_version} 无法唯一确定 Beta 发布分支：#{branches.join(', ')}"
    end
  end

  class TaskPlanner
    def initialize(branch_resolver:, note:)
      @branch_resolver = branch_resolver
      @note = note
    end

    def build(scan_results, overrides: {})
      scan_results.map do |scan_result|
        build_task(scan_result, overrides)
      rescue Error => e
        blocked_task(scan_result, e)
      end
    end

    private

    def build_task(scan_result, overrides)
      component = scan_result.fetch(:component)
      artifact_version = scan_result.fetch(:artifact_version)
      version = VersionInfo.parse(artifact_version)
      branch = @branch_resolver.resolve(
        component: component,
        artifact_version: artifact_version,
        override: overrides[component]
      )
      route = JobRouter.route(
        component: component,
        artifact_version: artifact_version,
        branch: branch,
        note: @note
      )
      scan_result.merge(
        source_version: version.source_version,
        branch: branch,
        status: 'ready'
      ).merge(route)
    end

    def blocked_task(scan_result, error)
      source_version = VersionInfo.parse(
        scan_result.fetch(:artifact_version)
      ).source_version
      scan_result.merge(
        source_version: source_version,
        status: 'blocked',
        error: error.message
      )
    end
  end

  class JobRouter
    TRIGGERED_FROM = 'PCM批量重打'

    def self.route(component:, artifact_version:, branch:, note:)
      version = VersionInfo.parse(artifact_version)
      return bt_assets_route(note, version) if component == 'BTAssets'
      return release_route(component, branch, note, version) unless version.beta?

      beta_route(component, branch, note, version)
    end

    def self.bt_assets_route(note, version)
      {
        job: '发布BTAssets',
        parameters: {
          'BRANCH' => version.bt_assets_branch,
          'UPDATE_NOTE' => note,
          'UPGRADE_SWIFT' => 'false',
          'TRIGGERED_FROM' => TRIGGERED_FROM
        }
      }
    end

    def self.beta_route(component, branch, note, version)
      {
        job: '发布组件_Beta',
        parameters: {
          'LIB_NAME' => RepositoryName.for(component),
          'BRANCH' => branch,
          'UPDATE_NOTE' => note,
          'MIXUP' => version.mixup?.to_s,
          'VI' => 'false',
          'WITHOUT_BUILD_CACHE' => 'true',
          'TRIGGERED_FROM' => TRIGGERED_FROM
        }
      }
    end

    def self.release_route(component, branch, note, version)
      {
        job: '发布组件',
        parameters: {
          'LIB_NAME' => RepositoryName.for(component),
          'BRANCH' => branch,
          'LIB_NOTE' => note,
          'LIB_ENABLE_MIXUP' => version.mixup?.to_s,
          'AUTO_MERGE_DEVELOP' => 'false',
          'TRIGGERED_FROM' => TRIGGERED_FROM
        }
      }
    end

    private_class_method :bt_assets_route
    private_class_method :beta_route
    private_class_method :release_route
  end

  class ProgressStore
    def initialize(path)
      @path = File.expand_path(path)
    end

    def entries(plan_path)
      document = load_document
      return {} unless document['plan_path'] == plan_path

      document.fetch('tasks', {}).each_with_object({}) do |(component, task), result|
        result[component] = task.each_with_object({}) do |(key, value), entry|
          entry[key.to_sym] = value
        end
      end
    end

    def record(plan_path, task)
      document = load_document
      unless document['plan_path'] == plan_path
        document = {
          'plan_path' => plan_path,
          'tasks' => {}
        }
      end
      document['tasks'][task.fetch(:component)] = task
      write(document)
    end

    private

    def load_document
      return {} unless File.file?(@path) && File.size?(@path)

      JSON.parse(File.read(@path))
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def write(document)
      FileUtils.mkdir_p(File.dirname(@path))
      temporary_path = "#{@path}.tmp-#{Process.pid}"
      File.open(temporary_path, 'w', 0o600) do |file|
        file.write(JSON.pretty_generate(document))
        file.write("\n")
      end
      File.rename(temporary_path, @path)
    ensure
      File.unlink(temporary_path) if temporary_path && File.exist?(temporary_path)
    end
  end

  class JenkinsExecutor
    def initialize(client:)
      @client = client
    end

    def execute(tasks, dry_run:, wait:, previous: {}, &callback)
      tasks.each do |task|
        @client&.validate_job!(task.fetch(:job), task.fetch(:parameters))
      end
      if dry_run
        return tasks.map do |task|
          task.merge(execution: @client ? 'validated' : 'planned')
        end
      end

      raise Error, '触发模式需要 Jenkins 凭据' unless @client

      queued_tasks = tasks.each_with_index.map do |task, index|
        queue_task(task, index, tasks.length, previous, &callback)
      end
      return queued_tasks unless wait

      queued_tasks.map { |task| monitor_task(task, &callback) }
    end

    private

    def queue_task(task, index, total, previous)
      progress = task.merge(position: index + 1, total: total)
      previous_task = previous.fetch(task.fetch(:component), {})
      queue_url = previous_task[:queue_url]
      return progress.merge(previous_task, queue_url: queue_url) unless queue_url.to_s.empty?

      yield progress.merge(execution: 'submitting') if block_given?
      queue_url = @client.trigger(task.fetch(:job), task.fetch(:parameters))
      queued_task = progress.merge(execution: 'queued', queue_url: queue_url)
      yield queued_task if block_given?
      queued_task
    rescue Error => e
      failed_task = progress.merge(execution: 'failed', error: e.message)
      yield failed_task if block_given?
      failed_task
    end

    def monitor_task(task)
      return task if task[:execution] == 'failed'

      queue_url = task.fetch(:queue_url)
      wait_result = @client.wait(queue_url, job: task.fetch(:job)) do |monitor_state|
        monitored_task = task.merge(
          monitor_state,
          queue_url: queue_url
        )
        yield monitored_task if block_given?
      end
      completed_task = task.merge(wait_result).merge(execution: 'completed')
      yield completed_task if block_given?
      completed_task
    rescue Error => e
      failed_task = task.merge(execution: 'monitor_failed', error: e.message)
      yield failed_task if block_given?
      failed_task
    end
  end

  class JenkinsClient
    def initialize(transport:, sleeper: ->(seconds) { sleep(seconds) }, poll_interval: 5)
      @transport = transport
      @sleeper = sleeper
      @poll_interval = poll_interval
    end

    def validate_job!(job, parameters)
      response = @transport.get("#{job_path(job)}/config.xml")
      ensure_response!(response, [200], "读取 Jenkins Job #{job}")
      document = REXML::Document.new(response.body)
      names = REXML::XPath.match(document, '//parameterDefinitions/*/name').map(&:text)
      missing = parameters.keys - names
      raise Error, "Jenkins Job #{job} 不支持参数：#{missing.join(', ')}" unless missing.empty?

      true
    rescue REXML::ParseException => e
      raise Error, "Jenkins Job #{job} 配置解析失败：#{e.message}"
    end

    def trigger(job, parameters)
      response = @transport.post_form(
        "#{job_path(job)}/buildWithParameters",
        parameters,
        crumb_header
      )
      ensure_response!(response, [201, 302], "触发 Jenkins Job #{job}")
      queue_url = response.headers['location']
      raise Error, "Jenkins Job #{job} 未返回队列地址" if queue_url.to_s.empty?

      queue_url
    end

    def wait(queue_url, job:)
      executable = wait_for_executable(queue_url, job)
      build_url = executable.fetch('url')
      yield(
        execution: 'building',
        build_url: build_url,
        build_number: executable.fetch('number')
      ) if block_given?
      build = wait_for_build(build_url) do
        yield(
          execution: 'monitoring',
          build_url: build_url,
          build_number: executable.fetch('number')
        ) if block_given?
      end
      result = {
        queue_url: queue_url,
        build_url: build_url,
        build_number: executable.fetch('number'),
        result: build.fetch('result')
      }
      version = published_version(build_url) if result[:result] == 'SUCCESS'
      result[:published_version] = version if version
      result
    end

    private

    def wait_for_executable(queue_url, job)
      loop do
        queue_item = read_queue_item(queue_url)
        if queue_item
          raise Error, "Jenkins 队列任务已取消：#{queue_url}" if queue_item['cancelled']

          return queue_item['executable'] if queue_item['executable']
        else
          executable = find_executable_by_queue_id(job, queue_url)
          return executable if executable
        end

        @sleeper.call(@poll_interval)
      end
    end

    def read_queue_item(queue_url)
      response = @transport.get(api_url(queue_url))
      return if response.code.to_i == 404

      ensure_response!(response, [200], '读取 Jenkins 队列')
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Error, "读取 Jenkins 队列响应解析失败：#{e.message}"
    end

    def find_executable_by_queue_id(job, queue_url)
      queue_id = queue_url[%r{/queue/item/(\d+)/?}, 1]
      raise Error, "无法从 Jenkins 队列地址提取 ID：#{queue_url}" unless queue_id

      tree = CGI.escape('builds[number,url,queueId]{0,100}')
      data = get_json(
        "#{job_path(job)}/api/json?tree=#{tree}",
        "按队列 ID 恢复 Jenkins Job #{job} 构建"
      )
      build = Array(data['builds']).find do |item|
        item['queueId'].to_s == queue_id
      end
      return unless build

      {
        'number' => build.fetch('number'),
        'url' => build.fetch('url')
      }
    rescue KeyError => e
      raise Error, "恢复 Jenkins 构建响应缺少字段：#{e.message}"
    end

    def wait_for_build(build_url)
      poll_count = 0
      loop do
        build = get_json(api_url(build_url), '读取 Jenkins 构建')
        return build unless build['building']

        poll_count += 1
        yield if block_given? && (poll_count % 6).zero?
        @sleeper.call(@poll_interval)
      end
    end

    def published_version(build_url)
      console_url = "#{build_url.sub(%r{/+\z}, '')}/consoleText"
      response = @transport.get(console_url)
      ensure_response!(response, [200], '读取 Jenkins 构建日志')
      text = response.body.dup.force_encoding('UTF-8').scrub
      text.scan(/[（(]版本\s+([^)）\s]+)[)）]/).last&.first
    rescue Error
      nil
    end

    def api_url(url)
      "#{url.sub(%r{/+\z}, '')}/api/json"
    end

    def get_json(path, action)
      response = @transport.get(path)
      ensure_response!(response, [200], action)
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Error, "#{action}响应解析失败：#{e.message}"
    end

    def crumb_header
      response = @transport.get('/crumbIssuer/api/json')
      return {} if response.code.to_i == 404

      ensure_response!(response, [200], '获取 Jenkins crumb')
      data = JSON.parse(response.body)
      { data.fetch('crumbRequestField') => data.fetch('crumb') }
    rescue JSON::ParserError, KeyError => e
      raise Error, "Jenkins crumb 解析失败：#{e.message}"
    end

    def job_path(job)
      "/job/#{CGI.escape(job).gsub('+', '%20')}"
    end

    def ensure_response!(response, expected_codes, action)
      return if expected_codes.include?(response.code.to_i)

      details = response.body.to_s.dup.force_encoding('UTF-8').scrub
                        .gsub(/<[^>]+>/, ' ')
                        .gsub(/\s+/, ' ')
                        .strip[0, 300]
      suffix = details.to_s.empty? ? '' : "：#{details}"
      raise Error, "#{action}失败，HTTP #{response.code}#{suffix}"
    end
  end

  class JenkinsTransport
    Response = Struct.new(:code, :body, :headers, keyword_init: true)

    def initialize(base_url:, user:, token:, requester: nil)
      @base_uri = URI(base_url)
      unless %w[http https].include?(@base_uri.scheme) && @base_uri.host
        raise Error, "非法 Jenkins 地址：#{base_url.inspect}"
      end

      @user = user
      @token = token
      @cookies = {}
      @requester = requester || method(:perform_request)
    end

    def get(target)
      request(target, Net::HTTP::Get)
    end

    def post_form(target, parameters, headers)
      request(target, Net::HTTP::Post, headers) do |http_request|
        http_request.set_form_data(parameters)
      end
    end

    private

    def request(target, request_class, headers = {})
      uri = resolve_uri(target)
      http_request = request_class.new(uri.request_uri, headers)
      http_request.basic_auth(@user, @token) if @user && @token
      http_request['Cookie'] = cookie_header unless @cookies.empty?
      yield http_request if block_given?
      response = @requester.call(uri, http_request)
      remember_cookies(response)
      response_headers = {}
      response.each_header { |name, value| response_headers[name.downcase] = value }
      Response.new(
        code: response.code.to_i,
        body: response.body.to_s,
        headers: response_headers
      )
    end

    def remember_cookies(response)
      values = if response.respond_to?(:get_fields)
                 response.get_fields('set-cookie')
               else
                 []
               end
      Array(values).each do |header|
        header.to_s.split(/,(?=[^;,]+=)/).each do |cookie|
          name, value = cookie.split(';', 2).first.to_s.split('=', 2)
          next unless name.to_s.match?(/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/)
          next if value.to_s.match?(/[\r\n]/)

          value.to_s.empty? ? @cookies.delete(name) : @cookies[name] = value
        end
      end
    end

    def cookie_header
      @cookies.map { |name, value| "#{name}=#{value}" }.join('; ')
    end

    def resolve_uri(target)
      target_uri = URI(target)
      request_target = target_uri.absolute? ? target_uri.request_uri : target
      uri = URI.join(@base_uri, request_target)
      unless uri.scheme == @base_uri.scheme &&
             uri.host == @base_uri.host &&
             uri.port == @base_uri.port
        raise Error, "拒绝向 Jenkins 以外的地址发送凭据：#{uri}"
      end

      uri
    end

    def perform_request(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 30
      http.request(request)
    end
  end

  class Options
    DEFAULT_NOTE = '修复二进制调试信息中的本机 PCM 引用'
    DEFAULT_GITLAB_URL = 'https://gitlab-code.v.show/api/v4/'

    def self.parse(arguments, script_directory: File.expand_path(__dir__))
      remaining_arguments = arguments.dup
      options = defaults(script_directory)
      parser = build_parser(options)
      parser.parse!(remaining_arguments)
      unless options[:help]
        raise Error, "必须且只能传入一个项目根目录\n#{parser}" unless remaining_arguments.length == 1

        options[:project_root] = remaining_arguments.first
      end
      options[:help_text] = parser.to_s
      options
    rescue OptionParser::ParseError => e
      raise Error, "#{e.message}\n#{parser}"
    end

    def self.defaults(script_directory)
      {
        project_root: nil,
        branch_file: File.join(script_directory, 'pcm_rebuild_branches.yml'),
        progress_file: File.join(script_directory, 'pcm_rebuild_progress.json'),
        gitlab_url: ENV.fetch('GIT_LAB_URL', DEFAULT_GITLAB_URL),
        gitlab_token: ENV.fetch('GIT_LAB_TOKEN', nil),
        dry_run: false,
        note: DEFAULT_NOTE,
        output: File.join(
          '/tmp',
          "pcm-rebuild-plan-#{Time.now.strftime('%Y%m%d-%H%M%S')}.json"
        ),
        jenkins_url: ENV.fetch('JENKINS_URL', 'http://127.0.0.1:8080/'),
        jenkins_user: ENV['JENKINS_USER'],
        help: false
      }
    end

    def self.build_parser(options)
      OptionParser.new do |parser|
        parser.banner = <<~BANNER
          用法：pcm_rebuild_once.rb 项目根目录 [--dry-run]

          --dry-run：扫描二进制、查询 GitLab 分支、更新固定 YAML 并校验 Jenkins，不提交构建。
          不传 --dry-run：读取最近一次成功 dry-run 的扫描结果，整批提交 Jenkins。
        BANNER
        parser.on('--dry-run', '只生成、更新并校验计划') { options[:dry_run] = true }
        parser.on('-h', '--help', '显示帮助') { options[:help] = true }
        parser.separator <<~HELP

          执行流程：
            1. 先执行：pcm_rebuild_once.rb 项目根目录 --dry-run
               扫描 PCM、查询发布分支、生成 YAML，并校验 Jenkins 参数。
            2. 确认 YAML 后执行：pcm_rebuild_once.rb 项目根目录
               直接读取最近一次成功计划，不重复扫描。
            3. 检查任务表，按回车提交到 Jenkins；输入其他内容取消。
            4. 所有任务先批量入队，再监控并汇总成功、失败和发布版本。
               中断后重新执行会恢复监控，已成功任务不会重复提交。
            5. 构建结束后可按回车只替换 Podfile 中的成功组件版本。
               不执行 pod install、pod update 或缓存清理。

          固定分支文件：
            #{options[:branch_file]}

          进度文件：
            #{options[:progress_file]}

          凭据从环境变量读取：
            GIT_LAB_TOKEN
            JENKINS_USER / JENKINS_TOKEN

          退出码：
            0  执行成功，或 dry-run 正常完成
            1  参数、配置、网络错误，或用户取消
            2  存在未确定发布分支的组件
            3  存在 Jenkins 触发或构建失败的组件
        HELP
      end
    end

    private_class_method :build_parser
  end

  class Application
    def self.run(arguments, output: $stdout, error_output: $stderr, input: $stdin)
      new(output: output, input: input).run(arguments)
    rescue Error => e
      error_output.puts("错误：#{e.message}")
      1
    end

    def initialize(output:, input: $stdin)
      @output = output
      @input = input
    end

    def run(arguments)
      options = Options.parse(arguments)
      if options[:help]
        @output.puts(options[:help_text])
        return 0
      end

      validate_options!(options)
      tasks, cached_plan_path = tasks_for(options)
      if options[:dry_run]
        branch_plan_path = BranchPlanWriter.write(options[:branch_file], tasks)
        @output.puts("分支文件：#{branch_plan_path}")
      else
        @output.puts("读取扫描结果：#{cached_plan_path}")
      end
      report = build_report(options, tasks)
      write_report(options[:output], report)
      print_plan(tasks, cached_plan_path || options[:output])

      if !options[:dry_run] && tasks.any? { |task| task[:status] == 'blocked' }
        raise Error, '存在无法确定发布分支的组件，已阻止全部 Jenkins 提交'
      end

      ready_tasks = tasks.select { |task| task[:status] == 'ready' }
      executed_tasks = if options[:dry_run]
                         execute(ready_tasks, options)
                       else
                         execute_trigger_tasks(
                           ready_tasks,
                           options,
                           cached_plan_path
                         )
                       end
      report[:tasks] = merge_executions(tasks, executed_tasks)
      report[:summary] = summary(report[:tasks])
      report[:completed_at] = Time.now.iso8601
      write_report(options[:output], report)
      print_execution_summary(report, options)
      offer_project_update(report, options) unless options[:dry_run]
      completion_status(options, report[:summary])
    end

    private

    def validate_options!(options)
      project_root = File.expand_path(options[:project_root])
      raise Error, "项目目录不存在：#{project_root}" unless File.directory?(project_root)
      raise Error, '更新日志不能为空' if options[:note].to_s.strip.empty?
      if options[:dry_run]
        raise Error, '必须设置 GIT_LAB_TOKEN' if options[:gitlab_token].to_s.empty?

        return
      end
      unless File.file?(options[:branch_file])
        raise Error, '找不到分支文件，请先使用 --dry-run 生成并确认'
      end
      raise Error, '实际触发必须设置 JENKINS_USER' if options[:jenkins_user].to_s.empty?
      raise Error, '实际触发必须设置 JENKINS_TOKEN' if jenkins_token.to_s.empty?
    end

    def tasks_for(options)
      if options[:dry_run]
        return [sort_tasks_by_pcm(create_tasks(options)), nil]
      end

      plan_path, tasks = load_cached_plan(options)
      [sort_tasks_by_pcm(tasks), plan_path]
    end

    def sort_tasks_by_pcm(tasks)
      tasks.sort_by do |task|
        [-task[:pcm_count].to_i, task[:component].to_s]
      end
    end

    def load_cached_plan(options)
      project_root = File.expand_path(options[:project_root])
      candidates = Dir.glob('/tmp/pcm-rebuild-plan-*.json')
                      .sort_by { |path| File.mtime(path) }
                      .reverse
      selected = candidates.filter_map do |path|
        document = JSON.parse(File.read(path))
        next unless reusable_plan?(document, project_root)

        [path, document]
      rescue JSON::ParserError, SystemCallError
        next
      end.first
      unless selected
        raise Error, '找不到当前项目成功的 dry-run 计划，请先执行一次 --dry-run'
      end

      path, document = selected
      tasks = document.fetch('tasks').map { |task| symbolize_task(task) }
      validate_cached_tasks!(options, tasks)
      [path, tasks]
    end

    def reusable_plan?(document, project_root)
      document['mode'] == 'dry-run' &&
        !document['completed_at'].to_s.empty? &&
        File.expand_path(document['project_root'].to_s) == project_root &&
        document.dig('summary', 'blocked').to_i.zero? &&
        Array(document['tasks']).all? do |task|
          task['status'] == 'ready' && task['execution'] == 'validated'
        end
    end

    def symbolize_task(task)
      task.each_with_object({}) do |(key, value), result|
        result[key.to_sym] = value
      end
    end

    def validate_cached_tasks!(options, tasks)
      project_root = File.expand_path(options[:project_root])
      versions = LockfileParser.parse(File.join(project_root, 'Podfile.lock'))
      branches = BranchOverrides.load(options[:branch_file])
      changed = tasks.filter_map do |task|
        component = task.fetch(:component)
        next if versions[component] == task[:artifact_version] &&
                branches[component] == task[:branch]

        component
      end
      return if changed.empty?

      raise Error, "项目版本或分支已变化，请重新执行 --dry-run：#{changed.join(', ')}"
    end

    def create_tasks(options)
      project_root = File.expand_path(options[:project_root])
      lockfile_path = File.join(project_root, 'Podfile.lock')
      versions = LockfileParser.parse(lockfile_path)
      raise Error, 'Podfile.lock 中没有符合条件的 BT 组件' if versions.empty?

      @output.puts("正在扫描 #{versions.length} 个已安装组件的二进制调试信息……")
      scan_results = PcmScanner.new(
        project_root,
        dwarf_scanner: DwarfScanner.new
      ).scan(versions)
      @output.puts("发现 #{scan_results.length} 个包含 PCM 路径的组件。")
      overrides = if File.file?(options[:branch_file])
                    BranchOverrides.load(options[:branch_file])
                  else
                    {}
                  end
      gitlab_client = GitLabClient.new(
        base_url: options[:gitlab_url],
        token: options[:gitlab_token]
      )
      provider = GitLabRepositoryProvider.new(client: gitlab_client)
      resolver = BranchResolver.new(repository_provider: provider)
      TaskPlanner.new(branch_resolver: resolver, note: options[:note]).build(
        scan_results,
        overrides: overrides
      )
    end

    def execute(ready_tasks, options, previous: {}, &block)
      client = jenkins_client(options)
      JenkinsExecutor.new(client: client).execute(
        ready_tasks,
        dry_run: options[:dry_run],
        wait: true,
        previous: previous,
        &block
      )
    end

    def execute_trigger_tasks(tasks, options, plan_path)
      progress_store = ProgressStore.new(options[:progress_file])
      previous = progress_store.entries(plan_path)
      completed = previous.select do |_component, task|
        task[:execution] == 'completed' && task[:result] == 'SUCCESS'
      end
      resumable = previous.select do |_component, task|
        %w[queued building monitoring monitor_failed].include?(task[:execution]) &&
          !task[:queue_url].to_s.empty?
      end
      remaining = tasks.reject { |task| completed.key?(task[:component]) }
      if remaining.empty?
        @output.puts('当前计划中的 Jenkins 任务已全部成功，无需重复提交。')
        return completed.values
      end

      confirm_trigger!(remaining.length, completed.length)
      executed = execute(remaining, options, previous: resumable) do |task|
        progress_store.record(plan_path, task)
        print_task_progress(task)
      end
      completed.values + executed
    end

    def confirm_trigger!(remaining_count, completed_count)
      @output.print(
        "剩余 #{remaining_count} 个任务，已完成跳过 #{completed_count} 个；" \
        '按回车提交到 Jenkins，输入其他内容取消：'
      )
      @output.flush if @output.respond_to?(:flush)
      answer = @input.gets
      raise Error, '已取消 Jenkins 提交' unless answer&.strip&.empty?
    end

    def print_task_progress(task)
      prefix = "[#{task[:position]}/#{task[:total]}]"
      case task[:execution]
      when 'submitting'
        @output.puts(
          "#{prefix} 正在提交 #{task[:component]} -> " \
          "#{task[:job]} / #{task[:branch]}"
        )
      when 'queued'
        @output.puts("[已入队] #{task[:component]}：#{task[:queue_url]}")
      when 'building'
        @output.puts(
          "[开始构建] #{task[:component]} ##{task[:build_number]}：#{task[:build_url]}"
        )
      when 'monitoring'
        @output.puts(
          "[监控中] #{task[:component]} ##{task[:build_number]} 仍在构建……"
        )
      when 'failed'
        @output.puts("[提交失败] #{task[:component]}：#{task[:error]}")
      when 'monitor_failed'
        @output.puts("[监控失败] #{task[:component]}：#{task[:error]}")
      when 'completed'
        @output.puts(
          "[#{task[:result]}] #{task[:component]}：#{task[:build_url]}"
        )
      end
    end

    def jenkins_client(options)
      token = jenkins_token
      return if options[:dry_run] && (options[:jenkins_user].to_s.empty? || token.to_s.empty?)

      transport = JenkinsTransport.new(
        base_url: options[:jenkins_url],
        user: options[:jenkins_user],
        token: token
      )
      JenkinsClient.new(transport: transport)
    end

    def jenkins_token
      ENV['JENKINS_TOKEN'] || ENV['JENKINS_API_TOKEN']
    end

    def build_report(options, tasks)
      {
        generated_at: Time.now.iso8601,
        mode: options[:dry_run] ? 'dry-run' : 'trigger',
        project_root: File.expand_path(options[:project_root]),
        podfile_lock: File.join(File.expand_path(options[:project_root]), 'Podfile.lock'),
        note: options[:note],
        summary: summary(tasks),
        tasks: tasks
      }
    end

    def summary(tasks)
      {
        affected: tasks.length,
        ready: tasks.count { |task| task[:status] == 'ready' },
        blocked: tasks.count { |task| task[:status] == 'blocked' },
        beta: tasks.count { |task| task[:job] == '发布组件_Beta' },
        release: tasks.count { |task| task[:job] == '发布组件' },
        assets: tasks.count { |task| task[:job] == '发布BTAssets' },
        jenkins_success: tasks.count { |task| task[:result] == 'SUCCESS' },
        jenkins_failed: tasks.count { |task| failed_execution?(task) }
      }
    end

    def completion_status(options, summary_data)
      return 0 if options[:dry_run]

      return 2 unless summary_data[:blocked].zero?
      return 3 unless summary_data[:jenkins_failed].zero?

      0
    end

    def failed_execution?(task)
      %w[failed monitor_failed].include?(task[:execution]) ||
        (task[:execution] == 'completed' &&
         !task[:result].to_s.empty? &&
         task[:result] != 'SUCCESS')
    end

    def merge_executions(tasks, executed_tasks)
      executions = executed_tasks.to_h { |task| [task[:component], task] }
      tasks.map { |task| task.merge(executions.fetch(task[:component], {})) }
    end

    def write_report(path, report)
      expanded_path = File.expand_path(path)
      FileUtils.mkdir_p(File.dirname(expanded_path))
      temporary_path = "#{expanded_path}.tmp-#{Process.pid}"
      File.open(temporary_path, 'w', 0o600) do |file|
        file.write(JSON.pretty_generate(report))
        file.write("\n")
      end
      File.rename(temporary_path, expanded_path)
    ensure
      File.unlink(temporary_path) if temporary_path && File.exist?(temporary_path)
    end

    def print_plan(tasks, report_path)
      headers = [
        '状态',
        '组件',
        '当前版本',
        'Jenkins Job',
        '发布分支',
        '是否混淆',
        'PCM 数量'
      ]
      rows = tasks.map do |task|
        [
          task[:status] == 'ready' ? '就绪' : '阻塞',
          task[:component],
          task[:artifact_version],
          task[:job] || '-',
          task[:status] == 'ready' ? task[:branch] : '待手动填写',
          mixup_label(task),
          task[:pcm_count]
        ]
      end
      print_terminal_table(headers, rows)
      tasks.select { |task| task[:status] == 'blocked' }.each do |task|
        @output.puts("[阻塞原因] #{task[:component]}：#{task[:error]}")
      end
      @output.puts("计划文件：#{File.expand_path(report_path)}")
    end

    def mixup_label(task)
      if task[:component] == 'BTAssets'
        return task[:branch].to_s == 'main' ? '否' : '是'
      end

      parameters = task[:parameters] || {}
      value = parameters['MIXUP'] || parameters['LIB_ENABLE_MIXUP']
      return value.to_s == 'true' ? '是' : '否' unless value.nil?

      VersionInfo.parse(task[:artifact_version]).mixup? ? '是' : '否'
    rescue Error
      '-'
    end

    def print_terminal_table(headers, rows)
      widths = headers.each_index.map do |index|
        ([headers[index]] + rows.map { |row| row[index] })
          .map { |value| display_width(value) }
          .max
      end
      @output.puts(table_border(widths, '┌', '┬', '┐'))
      @output.puts(table_row(headers, widths))
      @output.puts(table_border(widths, '├', '┼', '┤'))
      rows.each { |row| @output.puts(table_row(row, widths)) }
      @output.puts(table_border(widths, '└', '┴', '┘'))
    end

    def table_border(widths, left, divider, right)
      "#{left}#{widths.map { |width| '─' * (width + 2) }.join(divider)}#{right}"
    end

    def table_row(values, widths)
      cells = values.each_with_index.map do |value, index|
        text = value.to_s
        " #{text}#{' ' * (widths[index] - display_width(text))} "
      end
      "│#{cells.join('│')}│"
    end

    def display_width(value)
      value.to_s.each_char.sum { |character| character.ascii_only? ? 1 : 2 }
    end

    def print_execution_summary(report, options)
      summary_data = report[:summary]
      mode = options[:dry_run] ? 'dry-run 完成' : 'Jenkins 提交完成'
      @output.puts(
        "#{mode}：影响 #{summary_data[:affected]}，就绪 #{summary_data[:ready]}，" \
        "阻塞 #{summary_data[:blocked]}。"
      )
      return if options[:dry_run]

      print_jenkins_results(report[:tasks])
      @output.puts(
        "Jenkins 结果：成功 #{summary_data[:jenkins_success]}，" \
        "失败 #{summary_data[:jenkins_failed]}。"
      )
    end

    def print_jenkins_results(tasks)
      headers = ['组件', 'Jenkins Job', '是否混淆', '构建号', '结果', '发布版本']
      rows = tasks.map do |task|
        [
          task[:component],
          task[:job],
          mixup_label(task),
          task[:build_number] || '-',
          task_result(task),
          task[:published_version] || '-'
        ]
      end
      print_terminal_table(headers, rows)
      tasks.select { |task| failed_execution?(task) }.each do |task|
        @output.puts("[失败原因] #{task[:component]}：#{task[:error] || task[:result]}")
      end
    end

    def task_result(task)
      return '触发失败' if task[:execution] == 'failed'
      return '监控失败' if task[:execution] == 'monitor_failed'
      return task[:result] unless task[:result].to_s.empty?

      task[:execution] || '-'
    end

    def offer_project_update(report, options)
      successful_tasks = report[:tasks].select { |task| task[:result] == 'SUCCESS' }
      return if successful_tasks.empty?
      return unless confirm_project_update!(successful_tasks.length)

      published_versions = successful_tasks.filter_map do |task|
        next if task[:published_version].to_s.empty?

        [
          task[:component],
          task[:published_version].sub(/\.swift-\d+(?:\.\d+)*\z/, '')
        ]
      end.to_h
      podfile_path = File.join(File.expand_path(options[:project_root]), 'Podfile')
      changes = PodfileUpdater.update(podfile_path, published_versions)
      if changes.empty?
        @output.puts('Podfile 已是成功组件的最新发布版本。')
      else
        changes.each do |component, (old_version, new_version)|
          @output.puts(
            "[Podfile] #{component}：#{old_version} -> #{new_version}"
          )
        end
      end
    end

    def confirm_project_update!(success_count)
      @output.print(
        "#{success_count} 个成功组件已发布；是否一键更新 Podfile 版本？" \
        '按回车更新，输入其他内容跳过：'
      )
      @output.flush if @output.respond_to?(:flush)
      @input.gets&.strip&.empty? || false
    end
  end
end

exit PcmRebuildOnce::Application.run(ARGV) if $PROGRAM_NAME == __FILE__
