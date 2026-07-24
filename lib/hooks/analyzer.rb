# frozen_string_literal: true

require 'cocoapods/resolver'
require 'molinillo'

module Pod
  class Installer
    # Adds an optional direct-dependency preflight before CocoaPods resolves the full graph.
    class Analyzer
      attr_accessor :precheck_dependencies

      alias origin_resolve_dependencies_without_precheck resolve_dependencies

      private

      def resolve_dependencies(locked_dependencies)
        precheck_podfile_dependencies!(precheck_resolver) if precheck_dependencies
        origin_resolve_dependencies_without_precheck(locked_dependencies)
      end

      # 预检只验证 Podfile 本身的约束，不叠加 Podfile.lock，避免把应由 pod update
      # 处理的锁定版本差异误报为仓库缺少版本。
      def precheck_resolver
        Resolver.new(
          sandbox,
          podfile,
          Molinillo::DependencyGraph.new,
          sources,
          @specs_updated,
          podfile_dependency_cache: @podfile_dependency_cache,
          sources_manager: sources_manager
        )
      end

      def precheck_podfile_dependencies!(resolver)
        missing_dependencies = podfile_dependencies.reject(&:external?).select do |dependency|
          dependency_unavailable?(resolver, dependency)
        end
        return if missing_dependencies.empty?

        dependency_list = missing_dependencies.map { |dependency| "  - #{dependency}" }.join("\n")
        message = <<~MESSAGE
          预检发现 #{missing_dependencies.count} 个无法找到兼容版本的 Podfile 依赖：

          #{dependency_list}

          请一次性修正以上版本后重新执行 pod install。
        MESSAGE
        raise NoSpecFoundError, message
      end

      def dependency_unavailable?(resolver, dependency)
        resolver.search_for(dependency).empty?
      rescue Molinillo::NoSuchDependencyError
        true
      end
    end
  end
end
