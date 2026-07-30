# frozen_string_literal: true

require File.expand_path('../spec_helper', __dir__)
require 'fileutils'
require 'stringio'
require 'tempfile'
require 'tmpdir'
require ROOT + 'scripts/pcm_rebuild_once'

describe PcmRebuildOnce::VersionInfo do
  it 'extracts the source version from a beta mixup artifact version' do
    version = PcmRebuildOnce::VersionInfo.parse('260.b20.VO-CF')

    version.source_version.should == '260.b20'
  end

  it 'identifies beta only from the source version' do
    version = PcmRebuildOnce::VersionInfo.parse('103.b1.VO-C.swift-6.3.3')

    version.beta?.should == true
  end

  it 'identifies class-obfuscated subspec artifacts as mixup builds' do
    version = PcmRebuildOnce::VersionInfo.parse('105.VO-SC')

    version.mixup?.should == true
  end

  it 'extracts the BTAssets branch after removing the Swift suffix' do
    version = PcmRebuildOnce::VersionInfo.parse('313.VONE.swift-6.3.3')

    version.bt_assets_branch.should == 'Vone'
  end

  it 'rejects artifact versions that cannot identify a source version' do
    -> { PcmRebuildOnce::VersionInfo.parse('VO-CF') }
      .should.raise(PcmRebuildOnce::Error)
  end
end

describe PcmRebuildOnce::LockfileParser do
  it 'returns installed versions for first-party root pods only' do
    lockfile = Tempfile.new('Podfile.lock')
    lockfile.write(<<~YAML)
      PODS:
        - BTBaseKit (287)
        - BTMultiPlayerPK (136.b1.VO-C):
          - BTBaseKit
        - BTInAppPurchase/VO_Framework (1.2.8)
        - SDWebImage (5.20.0)
      EXTERNAL SOURCES:
        BTBaseKit:
          :path: "../BaiTuPods/BTBaseKit"
    YAML
    lockfile.close

    PcmRebuildOnce::LockfileParser.parse(lockfile.path).should == {
      'BTBaseKit' => '287',
      'BTMultiPlayerPK' => '136.b1.VO-C',
      'BTInAppPurchase' => '1.2.8'
    }
  ensure
    lockfile&.unlink
  end
end

describe PcmRebuildOnce::BranchOverrides do
  it 'loads a component-to-branch YAML mapping' do
    file = Tempfile.new('pcm-branches.yml')
    file.write(<<~YAML)
      BTLiveRoom: feature/pcm-rebuild
      BTBaseKit: main
    YAML
    file.close

    PcmRebuildOnce::BranchOverrides.load(file.path).should == {
      'BTLiveRoom' => 'feature/pcm-rebuild',
      'BTBaseKit' => 'main'
    }
  ensure
    file&.unlink
  end

  it 'ignores blank branches so the generated YAML can be completed manually' do
    file = Tempfile.new('pcm-branches.yml')
    file.write(<<~YAML)
      BTLiveRoom: feature/pcm-rebuild
      BTSearchSwift:
    YAML
    file.close

    PcmRebuildOnce::BranchOverrides.load(file.path).should == {
      'BTLiveRoom' => 'feature/pcm-rebuild'
    }
  ensure
    file&.unlink
  end

  it 'treats a comment-only branch file as an empty mapping' do
    file = Tempfile.new('pcm-branches.yml')
    file.write(<<~YAML)
      # PCM 组件发布分支；空值需要确认后手动填写
      # 填写完成后再次执行脚本；脚本会自动读取本文件
    YAML
    file.close

    PcmRebuildOnce::BranchOverrides.load(file.path).should == {}
  ensure
    file&.unlink
  end
end

describe PcmRebuildOnce::BranchPlanWriter do
  it 'writes resolved branches and leaves blocked branches empty for manual editing' do
    file = Tempfile.new('pcm-branches.yml')
    file.close
    tasks = [
      {
        component: 'BTBaseKit',
        artifact_version: '287',
        source_version: '287',
        status: 'ready',
        branch: 'main',
        job: '发布组件'
      },
      {
        component: 'BTHomepageKit',
        artifact_version: '103.b5.VO-C',
        source_version: '103.b5',
        status: 'blocked',
        error: '找不到版本提交'
      }
    ]

    PcmRebuildOnce::BranchPlanWriter.write(file.path, tasks)

    YAML.safe_load(File.read(file.path), aliases: false).should == {
      'BTBaseKit' => 'main',
      'BTHomepageKit' => nil
    }
    File.read(file.path).should.include?('# TODO: 找不到版本提交')
  ensure
    file&.unlink
  end
end

describe PcmRebuildOnce::PcmScanner do
  it 'returns only installed components whose framework binaries reference PCM files' do
    Dir.mktmpdir do |root|
      affected_binary = File.join(root, 'Pods/BTBaseKit/BTBaseKit.framework/BTBaseKit')
      clean_binary = File.join(root, 'Pods/BTDeviceKit/BTDeviceKit.framework/BTDeviceKit')
      FileUtils.mkdir_p(File.dirname(affected_binary))
      FileUtils.mkdir_p(File.dirname(clean_binary))
      FileUtils.touch([affected_binary, clean_binary])
      dwarf_scanner = Object.new
      dwarf_scanner.define_singleton_method(:count) do |path|
        path == affected_binary ? 3 : 0
      end

      result = PcmRebuildOnce::PcmScanner.new(root, dwarf_scanner: dwarf_scanner).scan(
        'BTBaseKit' => '287',
        'BTDeviceKit' => '138.VO-C'
      )

      result.should == [
        {
          component: 'BTBaseKit',
          artifact_version: '287',
          pcm_count: 3,
          binaries: [affected_binary]
        }
      ]
    end
  end
end

describe PcmRebuildOnce::DwarfScanner do
  it 'counts PCM paths from DWARF output' do
    runner = Object.new
    runner.define_singleton_method(:each_output_line) do |*_command, &block|
      [
        "DW_AT_GNU_dwo_name (\"/tmp/UIKit-ABC.pcm\")\n",
        "DW_AT_name (\"SomeType\")\n",
        "DW_AT_name (\"not-a-module.pcm\")\n",
        "DW_AT_GNU_dwo_name (\"/tmp/Foundation-DEF.pcm\")\n"
      ].each(&block)
    end

    PcmRebuildOnce::DwarfScanner.new(runner: runner).count('/tmp/BTBaseKit').should == 2
  end
end

describe PcmRebuildOnce::BranchResolver do
  it 'chooses main when a release update commit is contained by main' do
    repository = Object.new
    repository.define_singleton_method(:find_update_commit) { |_version| 'abc123' }
    repository.define_singleton_method(:branches_containing) do |_commit|
      %w[feature/old main]
    end
    repository.define_singleton_method(:head_commit) { |_branch| 'other' }
    provider = Object.new
    provider.define_singleton_method(:repository) { |_component| repository }

    resolver = PcmRebuildOnce::BranchResolver.new(repository_provider: provider)

    resolver.resolve(component: 'BTBaseKit', artifact_version: '287').should == 'main'
  end

  it 'chooses the branch whose head is the beta update commit' do
    repository = Object.new
    repository.define_singleton_method(:find_update_commit) { |_version| 'abc123' }
    repository.define_singleton_method(:branches_containing) do |_commit|
      %w[develop feature/beta-publish]
    end
    repository.define_singleton_method(:head_commit) do |branch|
      branch == 'feature/beta-publish' ? 'abc123' : 'other'
    end
    provider = Object.new
    provider.define_singleton_method(:repository) { |_component| repository }

    resolver = PcmRebuildOnce::BranchResolver.new(repository_provider: provider)

    resolver.resolve(
      component: 'BTLiveRoom',
      artifact_version: '260.b20.VO-CF'
    ).should == 'feature/beta-publish'
  end
end

describe PcmRebuildOnce::GitLabRepository do
  it 'finds the exact update commit across paginated GitLab results' do
    client = Object.new
    client.define_singleton_method(:commits) do |_component, page:|
      case page
      when 1
        [
          [{ 'id' => 'bbb456', 'title' => '[Update] (260.b2)' }],
          '2'
        ]
      when 2
        [
          [{ 'id' => 'aaa123', 'title' => '[Update] (260.b20)' }],
          nil
        ]
      else
        raise "unexpected page #{page}"
      end
    end
    repository = PcmRebuildOnce::GitLabRepository.new('BTLiveRoom', client: client)

    repository.find_update_commit('260.b20').should == 'aaa123'
  end

  it 'accepts a Swift-toolchain update commit for the same source version' do
    client = Object.new
    client.define_singleton_method(:commits) do |_component, page:|
      page.should == 1
      [
        [{ 'id' => 'aaa123', 'title' => '[Update] (124.swift-6.2)' }],
        nil
      ]
    end
    repository = PcmRebuildOnce::GitLabRepository.new('BTGlobalConfig', client: client)

    repository.find_update_commit('124').should == 'aaa123'
  end

  it 'returns branch refs and the selected branch head from GitLab' do
    client = Object.new
    client.define_singleton_method(:commit_branches) do |component, commit|
      component.should == 'BTLiveRoom'
      commit.should == 'aaa123'
      %w[develop feature/beta-publish]
    end
    client.define_singleton_method(:branch_head) do |component, branch|
      component.should == 'BTLiveRoom'
      branch.should == 'feature/beta-publish'
      'aaa123'
    end
    repository = PcmRebuildOnce::GitLabRepository.new('BTLiveRoom', client: client)

    repository.branches_containing('aaa123').should == %w[develop feature/beta-publish]
    repository.head_commit('feature/beta-publish').should == 'aaa123'
  end
end

describe PcmRebuildOnce::GitLabClient do
  it 'queries the encoded component project using the local GitLab token' do
    captured = nil
    response = Object.new
    response.define_singleton_method(:code) { '200' }
    response.define_singleton_method(:body) do
      '[{"id":"aaa123","title":"[Update] (260.b20)"}]'
    end
    response.define_singleton_method(:each_header) do |_block = nil, &block|
      { 'x-next-page' => '2' }.each(&block)
    end
    requester = lambda do |uri, request|
      captured = [uri, request]
      response
    end
    client = PcmRebuildOnce::GitLabClient.new(
      base_url: 'https://gitlab.example/api/v4/',
      token: 'gitlab-secret',
      requester: requester
    )

    commits, next_page = client.commits('BTLiveRoom', page: 1)

    captured[0].path.should == '/api/v4/projects/ios_component%2FBTLiveRoom/repository/commits'
    captured[0].query.should.include?('all=true')
    captured[1]['PRIVATE-TOKEN'].should == 'gitlab-secret'
    commits.first['id'].should == 'aaa123'
    next_page.should == '2'
  end
end

describe PcmRebuildOnce::GitLabRepositoryProvider do
  it 'creates an API-backed repository for a valid component' do
    client = Object.new
    provider = PcmRebuildOnce::GitLabRepositoryProvider.new(client: client)

    provider.repository('BTBaseKit').should.be.kind_of(PcmRebuildOnce::GitLabRepository)
  end

  it 'maps BTSearchSwift to its BTSearchRecommendSwift repository' do
    requested_component = nil
    client = Object.new
    client.define_singleton_method(:commits) do |component, page:|
      requested_component = component
      page.should == 1
      [[{ 'id' => 'search100', 'title' => '[Update] (100)' }], '']
    end
    provider = PcmRebuildOnce::GitLabRepositoryProvider.new(client: client)

    provider.repository('BTSearchSwift').find_update_commit('100')

    requested_component.should == 'BTSearchRecommendSwift'
  end
end

describe PcmRebuildOnce::TaskPlanner do
  it 'combines scan, source branch, and Jenkins routing into a ready task' do
    resolver = Object.new
    resolver.define_singleton_method(:resolve) do |component:, artifact_version:, override:|
      component.should == 'BTLiveRoom'
      artifact_version.should == '260.b20.VO-CF'
      override.should == 'feature/manual'
      'feature/manual'
    end
    planner = PcmRebuildOnce::TaskPlanner.new(
      branch_resolver: resolver,
      note: '修复 PCM'
    )

    tasks = planner.build(
      [
        {
          component: 'BTLiveRoom',
          artifact_version: '260.b20.VO-CF',
          pcm_count: 4,
          binaries: ['/tmp/BTLiveRoom']
        }
      ],
      overrides: { 'BTLiveRoom' => 'feature/manual' }
    )

    tasks.first.should == {
      component: 'BTLiveRoom',
      artifact_version: '260.b20.VO-CF',
      source_version: '260.b20',
      pcm_count: 4,
      binaries: ['/tmp/BTLiveRoom'],
      branch: 'feature/manual',
      status: 'ready',
      job: '发布组件_Beta',
      parameters: {
        'LIB_NAME' => 'BTLiveRoom',
        'BRANCH' => 'feature/manual',
        'UPDATE_NOTE' => '修复 PCM',
        'MIXUP' => 'true',
        'VI' => 'false',
        'WITHOUT_BUILD_CACHE' => 'true',
        'TRIGGERED_FROM' => 'PCM批量重打'
      }
    }
  end

  it 'keeps the derived source version when branch resolution is blocked' do
    resolver = Object.new
    resolver.define_singleton_method(:resolve) do |**_arguments|
      raise PcmRebuildOnce::Error, 'missing branch'
    end
    planner = PcmRebuildOnce::TaskPlanner.new(
      branch_resolver: resolver,
      note: '修复 PCM'
    )

    task = planner.build(
      [
        {
          component: 'BTHomepageKit',
          artifact_version: '103.b5.VO-C',
          pcm_count: 1,
          binaries: ['/tmp/BTHomepageKit']
        }
      ]
    ).first

    task[:source_version].should == '103.b5'
    task[:status].should == 'blocked'
  end
end

describe PcmRebuildOnce::JobRouter do
  it 'routes beta artifacts to the existing beta publish job' do
    route = PcmRebuildOnce::JobRouter.route(
      component: 'BTLiveRoom',
      artifact_version: '260.b20.VO-CF',
      branch: 'feature/audio-support',
      note: '修复 PCM'
    )

    route.should == {
      job: '发布组件_Beta',
      parameters: {
        'LIB_NAME' => 'BTLiveRoom',
        'BRANCH' => 'feature/audio-support',
        'UPDATE_NOTE' => '修复 PCM',
        'MIXUP' => 'true',
        'VI' => 'false',
        'WITHOUT_BUILD_CACHE' => 'true',
        'TRIGGERED_FROM' => 'PCM批量重打'
      }
    }
  end

  it 'routes release artifacts to the existing release publish job' do
    route = PcmRebuildOnce::JobRouter.route(
      component: 'BTBaseKit',
      artifact_version: '287',
      branch: 'main',
      note: '修复 PCM'
    )

    route.should == {
      job: '发布组件',
      parameters: {
        'LIB_NAME' => 'BTBaseKit',
        'BRANCH' => 'main',
        'LIB_NOTE' => '修复 PCM',
        'LIB_ENABLE_MIXUP' => 'false',
        'AUTO_MERGE_DEVELOP' => 'false',
        'TRIGGERED_FROM' => 'PCM批量重打'
      }
    }
  end

  it 'submits the repository name for an aliased component' do
    route = PcmRebuildOnce::JobRouter.route(
      component: 'BTSearchSwift',
      artifact_version: '100.VO-C',
      branch: 'main',
      note: '修复 PCM'
    )

    route[:parameters]['LIB_NAME'].should == 'BTSearchRecommendSwift'
  end

  it 'routes BTAssets to its dedicated job and version-derived branch' do
    route = PcmRebuildOnce::JobRouter.route(
      component: 'BTAssets',
      artifact_version: '313.VONE.swift-6.3.3',
      branch: nil,
      note: '修复 PCM'
    )

    route.should == {
      job: '发布BTAssets',
      parameters: {
        'BRANCH' => 'Vone',
        'UPDATE_NOTE' => '修复 PCM',
        'UPGRADE_SWIFT' => 'false',
        'TRIGGERED_FROM' => 'PCM批量重打'
      }
    }
  end
end

describe PcmRebuildOnce::JenkinsExecutor do
  it 'validates dry-run tasks without triggering Jenkins builds' do
    client = Object.new
    client.define_singleton_method(:validate_job!) { |_job, _parameters| true }
    client.define_singleton_method(:trigger) { |_job, _parameters| raise 'must not trigger' }
    executor = PcmRebuildOnce::JenkinsExecutor.new(client: client)
    tasks = [
      {
        component: 'BTBaseKit',
        job: '发布组件',
        parameters: { 'LIB_NAME' => 'BTBaseKit' }
      }
    ]

    executor.execute(tasks, dry_run: true, wait: true).should == [
      {
        component: 'BTBaseKit',
        job: '发布组件',
        parameters: { 'LIB_NAME' => 'BTBaseKit' },
        execution: 'validated'
      }
    ]
  end

  it 'resumes waiting for an already queued task without triggering it again' do
    client = Object.new
    client.define_singleton_method(:validate_job!) { |_job, _parameters| true }
    client.define_singleton_method(:trigger) do |_job, _parameters|
      raise 'must not trigger again'
    end
    client.define_singleton_method(:wait) do |queue_url, job:|
      queue_url.should == 'http://jenkins/queue/item/12/'
      job.should == '发布组件'
      {
        queue_url: queue_url,
        build_url: 'http://jenkins/job/test/34/',
        build_number: 34,
        result: 'SUCCESS'
      }
    end
    task = {
      component: 'BTBaseKit',
      job: '发布组件',
      parameters: { 'LIB_NAME' => 'BTBaseKit' }
    }
    executor = PcmRebuildOnce::JenkinsExecutor.new(client: client)

    result = executor.execute(
      [task],
      dry_run: false,
      wait: true,
      previous: {
        'BTBaseKit' => {
          component: 'BTBaseKit',
          execution: 'queued',
          queue_url: 'http://jenkins/queue/item/12/'
        }
      }
    )

    result.first[:build_number].should == 34
    result.first[:result].should == 'SUCCESS'
  end

  it 'records a trigger failure and continues submitting later tasks' do
    client = Object.new
    client.define_singleton_method(:validate_job!) { |_job, _parameters| true }
    client.define_singleton_method(:trigger) do |job, _parameters|
      raise PcmRebuildOnce::Error, 'HTTP 500' if job == '发布BTAssets'

      'http://jenkins/queue/item/12/'
    end
    client.define_singleton_method(:wait) do |queue_url, job:|
      job.should == '发布组件'
      {
        queue_url: queue_url,
        build_url: 'http://jenkins/job/test/34/',
        build_number: 34,
        result: 'SUCCESS',
        published_version: '287.swift-6.3.3'
      }
    end
    tasks = [
      {
        component: 'BTAssets',
        job: '发布BTAssets',
        parameters: { 'BRANCH' => 'VONE' }
      },
      {
        component: 'BTBaseKit',
        job: '发布组件',
        parameters: { 'LIB_NAME' => 'BTBaseKit' }
      }
    ]
    states = []
    executor = PcmRebuildOnce::JenkinsExecutor.new(client: client)

    results = executor.execute(tasks, dry_run: false, wait: true) do |state|
      states << state
    end

    results.first[:execution].should == 'failed'
    results.first[:error].should.include?('HTTP 500')
    results.last[:result].should == 'SUCCESS'
    states.map { |state| state[:execution] }.should.include?('submitting')
    states.map { |state| state[:execution] }.should.include?('failed')
  end

  it 'queues every task before monitoring the first build' do
    events = []
    client = Object.new
    client.define_singleton_method(:validate_job!) { |_job, _parameters| true }
    client.define_singleton_method(:trigger) do |_job, parameters|
      component = parameters.fetch('LIB_NAME')
      events << "trigger:#{component}"
      "http://jenkins/queue/#{component}/"
    end
    client.define_singleton_method(:wait) do |queue_url, job:|
      job.should == '发布组件'
      component = queue_url.split('/')[-1]
      events << "wait:#{component}"
      {
        queue_url: queue_url,
        build_url: "http://jenkins/job/#{component}/1/",
        build_number: 1,
        result: 'SUCCESS'
      }
    end
    tasks = %w[BTBaseKit BTLogger].map do |component|
      {
        component: component,
        job: '发布组件',
        parameters: { 'LIB_NAME' => component }
      }
    end
    executor = PcmRebuildOnce::JenkinsExecutor.new(client: client)

    executor.execute(tasks, dry_run: false, wait: true)

    events.should == [
      'trigger:BTBaseKit',
      'trigger:BTLogger',
      'wait:BTBaseKit',
      'wait:BTLogger'
    ]
  end
end

describe PcmRebuildOnce::ProgressStore do
  it 'persists queued and completed Jenkins task state for the same plan' do
    file = Tempfile.new('pcm-progress.json')
    file.close
    store = PcmRebuildOnce::ProgressStore.new(file.path)
    queued = {
      component: 'BTBaseKit',
      execution: 'queued',
      queue_url: 'http://jenkins/queue/item/12/'
    }
    completed = queued.merge(
      execution: 'completed',
      build_number: 34,
      result: 'SUCCESS'
    )

    store.record('/tmp/plan.json', queued)
    store.record('/tmp/plan.json', completed)

    store.entries('/tmp/plan.json').should == {
      'BTBaseKit' => completed
    }
  ensure
    file&.unlink
  end
end

describe PcmRebuildOnce::JenkinsClient do
  it 'validates submitted parameter names against the existing Jenkins job' do
    response = Struct.new(:code, :body, :headers).new(
      200,
      <<~XML,
        <project>
          <properties>
            <hudson.model.ParametersDefinitionProperty>
              <parameterDefinitions>
                <hudson.model.StringParameterDefinition>
                  <name>LIB_NAME</name>
                </hudson.model.StringParameterDefinition>
                <hudson.model.StringParameterDefinition>
                  <name>BRANCH</name>
                </hudson.model.StringParameterDefinition>
              </parameterDefinitions>
            </hudson.model.ParametersDefinitionProperty>
          </properties>
        </project>
      XML
      {}
    )
    transport = Object.new
    transport.define_singleton_method(:get) { |_path| response }
    client = PcmRebuildOnce::JenkinsClient.new(transport: transport)

    client.validate_job!(
      '发布组件',
      'LIB_NAME' => 'BTBaseKit',
      'BRANCH' => 'main'
    ).should == true
  end

  it 'submits build parameters with the Jenkins crumb and returns the queue URL' do
    response_type = Struct.new(:code, :body, :headers)
    transport = Object.new
    transport.define_singleton_method(:get) do |path|
      raise "unexpected GET #{path}" unless path == '/crumbIssuer/api/json'

      response_type.new(
        200,
        '{"crumbRequestField":"Jenkins-Crumb","crumb":"crumb-value"}',
        {}
      )
    end
    transport.define_singleton_method(:post_form) do |path, parameters, headers|
      path.should == '/job/%E5%8F%91%E5%B8%83%E7%BB%84%E4%BB%B6/buildWithParameters'
      parameters.should == { 'LIB_NAME' => 'BTBaseKit' }
      headers.should == { 'Jenkins-Crumb' => 'crumb-value' }
      response_type.new(201, '', { 'location' => 'http://jenkins/queue/item/12/' })
    end
    client = PcmRebuildOnce::JenkinsClient.new(transport: transport)

    client.trigger(
      '发布组件',
      'LIB_NAME' => 'BTBaseKit'
    ).should == 'http://jenkins/queue/item/12/'
  end

  it 'waits for a queued build and returns its final Jenkins result' do
    response_type = Struct.new(:code, :body, :headers)
    transport = Object.new
    transport.define_singleton_method(:get) do |path|
      case path
      when 'http://jenkins/queue/item/12/api/json'
        response_type.new(
          200,
          '{"executable":{"number":34,"url":"http://jenkins/job/test/34/"}}',
          {}
        )
      when 'http://jenkins/job/test/34/api/json'
        response_type.new(200, '{"building":false,"result":"SUCCESS"}', {})
      when 'http://jenkins/job/test/34/consoleText'
        response_type.new(
          200,
          "构建 [普通版] BTBaseKit（版本 287.swift-6.3.3）\n",
          {}
        )
      else
        raise "unexpected GET #{path}"
      end
    end
    client = PcmRebuildOnce::JenkinsClient.new(
      transport: transport,
      sleeper: ->(_seconds) {}
    )

    client.wait(
      'http://jenkins/queue/item/12/',
      job: '发布组件'
    ).should == {
      queue_url: 'http://jenkins/queue/item/12/',
      build_url: 'http://jenkins/job/test/34/',
      build_number: 34,
      result: 'SUCCESS',
      published_version: '287.swift-6.3.3'
    }
  end

  it 'recovers a build by queue ID after Jenkins removes the queue item' do
    response_type = Struct.new(:code, :body, :headers)
    transport = Object.new
    transport.define_singleton_method(:get) do |path|
      case path
      when 'http://jenkins/queue/item/12/api/json'
        response_type.new(404, 'Not Found', {})
      when %r{\A/job/.+/api/json\?tree=}
        response_type.new(
          200,
          <<~JSON,
            {
              "builds": [
                {
                  "number": 34,
                  "url": "http://jenkins/job/test/34/",
                  "queueId": 12
                }
              ]
            }
          JSON
          {}
        )
      when 'http://jenkins/job/test/34/api/json'
        response_type.new(200, '{"building":false,"result":"SUCCESS"}', {})
      when 'http://jenkins/job/test/34/consoleText'
        response_type.new(
          200,
          "构建 BTBaseKit（版本 288.swift-6.3.3）\n",
          {}
        )
      else
        raise "unexpected GET #{path}"
      end
    end
    client = PcmRebuildOnce::JenkinsClient.new(
      transport: transport,
      sleeper: ->(_seconds) {}
    )

    client.wait(
      'http://jenkins/queue/item/12/',
      job: '发布组件'
    ).should == {
      queue_url: 'http://jenkins/queue/item/12/',
      build_url: 'http://jenkins/job/test/34/',
      build_number: 34,
      result: 'SUCCESS',
      published_version: '288.swift-6.3.3'
    }
  end
end

describe PcmRebuildOnce::PodfileUpdater do
  it 'updates active root and subspec declarations while preserving comments' do
    file = Tempfile.new('Podfile')
    file.write(<<~RUBY)
      pod 'BTBaseKit', '287'
      pod 'BTAssets/Resource', '313.VONE' # assets
      # pod 'BTBaseKit', 'old'
      pod 'SDWebImage', '5.20.0'
    RUBY
    file.close

    changes = PcmRebuildOnce::PodfileUpdater.update(
      file.path,
      'BTBaseKit' => '288',
      'BTAssets' => '314.VONE'
    )

    File.read(file.path).should.include?("pod 'BTBaseKit', '288'")
    File.read(file.path).should.include?(
      "pod 'BTAssets/Resource', '314.VONE' # assets"
    )
    File.read(file.path).should.include?("# pod 'BTBaseKit', 'old'")
    changes.should == {
      'BTBaseKit' => ['287', '288'],
      'BTAssets' => ['313.VONE', '314.VONE']
    }
  ensure
    file&.unlink
  end
end

describe PcmRebuildOnce::JenkinsTransport do
  it 'sends authenticated requests only to the configured Jenkins origin' do
    captured = nil
    response = Object.new
    response.define_singleton_method(:code) { '200' }
    response.define_singleton_method(:body) { '<project />' }
    response.define_singleton_method(:each_header) { |_block = nil, &block| {}.each(&block) }
    requester = lambda do |uri, request|
      captured = [uri, request]
      response
    end
    transport = PcmRebuildOnce::JenkinsTransport.new(
      base_url: 'http://127.0.0.1:8080/',
      user: 'tester',
      token: 'secret',
      requester: requester
    )

    result = transport.get('/job/test/config.xml')

    captured[0].to_s.should == 'http://127.0.0.1:8080/job/test/config.xml'
    captured[1]['Authorization'].should.start_with('Basic ')
    result.code.should == 200
  end

  it 'reuses the Jenkins session cookie returned with the crumb request' do
    response_type = Struct.new(:code, :body, :headers) do
      def each_header(&block)
        headers.each(&block)
      end

      def get_fields(name)
        value = headers[name.downcase]
        value ? [value] : nil
      end
    end
    requests = []
    requester = lambda do |_uri, request|
      requests << request
      if requests.length == 1
        response_type.new(
          '200',
          '{"crumb":"value"}',
          { 'set-cookie' => 'JSESSIONID=abc123; Path=/; HttpOnly' }
        )
      else
        response_type.new('201', '', {})
      end
    end
    transport = PcmRebuildOnce::JenkinsTransport.new(
      base_url: 'http://127.0.0.1:8080/',
      user: 'tester',
      token: 'secret',
      requester: requester
    )

    transport.get('/crumbIssuer/api/json')
    transport.post_form('/job/test/buildWithParameters', {}, {})

    requests.last['Cookie'].should == 'JSESSIONID=abc123'
  end

  it 'rewrites a Jenkins-advertised host alias onto the configured origin' do
    captured_uri = nil
    response = Object.new
    response.define_singleton_method(:code) { '200' }
    response.define_singleton_method(:body) { '{}' }
    response.define_singleton_method(:each_header) { |_block = nil, &block| {}.each(&block) }
    response.define_singleton_method(:get_fields) { |_name| nil }
    requester = lambda do |uri, _request|
      captured_uri = uri
      response
    end
    transport = PcmRebuildOnce::JenkinsTransport.new(
      base_url: 'http://127.0.0.1:8080/',
      user: 'tester',
      token: 'secret',
      requester: requester
    )

    transport.get('http://xy-macbook-pro.local:8080/job/test/759/api/json')

    captured_uri.to_s.should == 'http://127.0.0.1:8080/job/test/759/api/json'
  end
end

describe PcmRebuildOnce::Options do
  it 'accepts only a project root and dry-run flag with a fixed branch YAML' do
    options = PcmRebuildOnce::Options.parse(
      %w[/tmp/app --dry-run],
      script_directory: '/tmp/scripts'
    )

    options[:project_root].should == '/tmp/app'
    options[:branch_file].should == '/tmp/scripts/pcm_rebuild_branches.yml'
    options[:dry_run].should == true
    options[:output].should.start_with?('/tmp/pcm-rebuild-plan-')
  end

  it 'uses actual Jenkins submission mode when dry-run is omitted' do
    options = PcmRebuildOnce::Options.parse(
      ['/tmp/app'],
      script_directory: '/tmp/scripts'
    )

    options[:dry_run].should == false
  end

  it 'rejects removed legacy options' do
    -> do
      PcmRebuildOnce::Options.parse(
        %w[--project-root /tmp/app],
        script_directory: '/tmp/scripts'
      )
    end.should.raise(PcmRebuildOnce::Error)
  end
end

describe PcmRebuildOnce::Application do
  it 'prints command help without scanning or contacting Jenkins' do
    output = StringIO.new

    PcmRebuildOnce::Application.run(['--help'], output: output).should == 0
    output.string.should.include?('项目根目录 [--dry-run]')
    output.string.should.include?('pcm_rebuild_branches.yml')
    output.string.should.include?('执行流程')
    output.string.should.include?('按回车提交到 Jenkins')
    output.string.should.include?('只替换 Podfile')
    output.string.should.include?('退出码')
  end

  it 'returns success for a completed dry-run even when manual branches remain' do
    application = PcmRebuildOnce::Application.new(output: StringIO.new)

    application.send(
      :completion_status,
      { dry_run: true },
      { blocked: 1 }
    ).should == 0
  end

  it 'prints the component plan as a terminal table with blocked details' do
    output = StringIO.new
    application = PcmRebuildOnce::Application.new(output: output)
    tasks = [
      {
        status: 'ready',
        component: 'BTBaseKit',
        artifact_version: '287',
        job: '发布组件',
        branch: 'main',
        pcm_count: 279,
        parameters: { 'LIB_ENABLE_MIXUP' => 'false' }
      },
      {
        status: 'blocked',
        component: 'BTSearchSwift',
        artifact_version: '100.VO-C',
        pcm_count: 1,
        error: '找不到版本提交'
      }
    ]

    application.send(:print_plan, tasks, '/tmp/plan.json')

    output.string.should.include?('│ 状态')
    output.string.should.include?('是否混淆')
    output.string.should.include?('│ 就绪')
    output.string.should.include?('│ 否')
    output.string.should.include?('BTSearchSwift')
    output.string.should.include?('待手动填写')
    output.string.should.include?('[阻塞原因] BTSearchSwift：找不到版本提交')
  end

  it 'shows Jenkins mixup parameters and BTAssets product branches as obfuscated' do
    application = PcmRebuildOnce::Application.new(output: StringIO.new)

    application.send(
      :mixup_label,
      component: 'BTLiveRoom',
      parameters: { 'MIXUP' => 'true' }
    ).should == '是'
    application.send(
      :mixup_label,
      component: 'BTAssets',
      branch: 'Vone',
      parameters: {}
    ).should == '是'
    application.send(
      :mixup_label,
      component: 'BTAssets',
      branch: 'main',
      parameters: {}
    ).should == '否'
  end

  it 'sorts component tasks by PCM count from highest to lowest' do
    application = PcmRebuildOnce::Application.new(output: StringIO.new)
    tasks = [
      { component: 'BTLogger', pcm_count: 3 },
      { component: 'BTVideoRecorderKit', pcm_count: 14_008 },
      { component: 'BTBaseKit', pcm_count: 279 }
    ]

    application.send(:sort_tasks_by_pcm, tasks).map do |task|
      task[:component]
    end.should == %w[BTVideoRecorderKit BTBaseKit BTLogger]
  end

  it 'loads the latest dry-run plan in trigger mode without scanning again' do
    application = PcmRebuildOnce::Application.new(output: StringIO.new)
    application.define_singleton_method(:create_tasks) do |_options|
      raise 'must not scan'
    end
    application.define_singleton_method(:load_cached_plan) do |_options|
      ['/tmp/pcm-rebuild-plan.json', [{ component: 'BTBaseKit' }]]
    end

    tasks, plan_path = application.send(:tasks_for, dry_run: false)

    tasks.should == [{ component: 'BTBaseKit' }]
    plan_path.should == '/tmp/pcm-rebuild-plan.json'
  end

  it 'requires pressing enter before submitting Jenkins tasks' do
    output = StringIO.new
    application = PcmRebuildOnce::Application.new(
      output: output,
      input: StringIO.new("\n")
    )

    application.send(:confirm_trigger!, 31, 1)

    output.string.should.include?('按回车提交到 Jenkins')
    output.string.should.include?('剩余 31')
    output.string.should.include?('已完成跳过 1')
  end

  it 'asks whether to update the project after successful builds' do
    output = StringIO.new
    application = PcmRebuildOnce::Application.new(
      output: output,
      input: StringIO.new("\n")
    )

    application.send(:confirm_project_update!, 30).should == true

    output.string.should.include?('一键更新 Podfile 版本')
    output.string.should.include?('30 个成功组件')
  end
end
