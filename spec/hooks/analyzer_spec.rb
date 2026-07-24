# frozen_string_literal: true

require File.expand_path('../spec_helper', __dir__)

module Pod
  # rubocop:disable Metrics/BlockLength -- Bacon keeps the related precheck scenarios in one group.
  describe Installer::Analyzer do
    before do
      @analyzer = Installer::Analyzer.allocate
    end

    it 'collects every unavailable direct Podfile dependency' do
      missing_version = Dependency.new('MissingVersion', '1.0.0')
      missing_name = Dependency.new('MissingName', '2.0.0')
      available = Dependency.new('AvailablePod', '3.0.0')
      local = Dependency.new('LocalPod', path: '/tmp/LocalPod')
      resolver = mock

      @analyzer.stubs(:podfile_dependencies).returns(
        [missing_version, available, local, missing_name]
      )
      resolver.expects(:search_for).with(missing_version).returns([])
      resolver.expects(:search_for).with(available).returns([mock])
      resolver.expects(:search_for).with(local).never
      resolver.expects(:search_for).with(missing_name)
              .raises(Molinillo::NoSuchDependencyError.new(missing_name))

      error = lambda do
        @analyzer.send(:precheck_podfile_dependencies!, resolver)
      end.should.raise NoSpecFoundError

      error.message.should.include '预检发现 2 个无法找到兼容版本的 Podfile 依赖'
      error.message.should.include 'MissingVersion (= 1.0.0)'
      error.message.should.include 'MissingName (= 2.0.0)'
      error.message.should.not.include 'AvailablePod'
      error.message.should.not.include 'LocalPod'
      error.message.scan(/\[!\]/).count.should.equal 1
      error.exit_status.should.equal 31
    end

    it 'continues when every direct Podfile dependency is available' do
      dependency = Dependency.new('AvailablePod', '1.0.0')
      resolver = mock

      @analyzer.stubs(:podfile_dependencies).returns([dependency])
      resolver.expects(:search_for).with(dependency).returns([mock])

      @analyzer.send(:precheck_podfile_dependencies!, resolver).should.be.nil
    end

    it 'builds the precheck resolver without Podfile.lock constraints' do
      dependency_cache = Struct.new(:podfile_dependencies).new([])
      @analyzer.instance_variable_set(:@podfile_dependency_cache, dependency_cache)
      @analyzer.instance_variable_set(:@specs_updated, true)
      @analyzer.stubs(:sandbox).returns(:sandbox)
      @analyzer.stubs(:podfile).returns(:podfile)
      @analyzer.stubs(:sources).returns([])
      @analyzer.stubs(:sources_manager).returns(:sources_manager)

      resolver = @analyzer.send(:precheck_resolver)

      resolver.should.be.instance_of Resolver
      resolver.locked_dependencies.should.be.instance_of Molinillo::DependencyGraph
      resolver.locked_dependencies.vertices.should.be.empty
    end

    it 'skips precheck when the option is disabled' do
      @analyzer.precheck_dependencies = false
      @analyzer.expects(:precheck_resolver).never
      @analyzer.expects(:precheck_podfile_dependencies!).never
      @analyzer.stubs(:origin_resolve_dependencies_without_precheck)
               .with(:locked_dependencies)
               .returns(:resolved)

      @analyzer.send(:resolve_dependencies, :locked_dependencies).should.equal :resolved
    end

    it 'runs precheck before the original resolver when enabled' do
      resolver = mock
      @analyzer.precheck_dependencies = true
      @analyzer.expects(:precheck_resolver).returns(resolver)
      @analyzer.expects(:precheck_podfile_dependencies!).with(resolver)
      @analyzer.stubs(:origin_resolve_dependencies_without_precheck)
               .with(:locked_dependencies)
               .returns(:resolved)

      @analyzer.send(:resolve_dependencies, :locked_dependencies).should.equal :resolved
    end
  end
  # rubocop:enable Metrics/BlockLength
end
