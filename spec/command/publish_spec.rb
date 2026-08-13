require File.expand_path('../../spec_helper', __FILE__)

module Pod
  describe Command::Publish do
    describe 'CLAide' do
      it 'registers it self' do
        Command.parse(%w{ publish }).should.be.instance_of Command::Publish
      end

      it 'accepts debug output in publish command' do
        command = Command.parse(%w{ publish BaiTuPods Example.podspec --from-wukong --debug })

        command.instance_variable_get(:@from_wukong).should == true
        command.instance_variable_get(:@debug).should == true
      end

      it 'accepts debug output in auto command' do
        command = Command.parse(%w{ publish auto --from-wukong --debug })

        command.instance_variable_get(:@from_wukong).should == true
        command.instance_variable_get(:@debug).should == true
      end

      it 'supports source-only auto publishing without requiring a binary artifact' do
        command = Command.parse(%w{ publish auto --skip-framework-publish })

        command.instance_variable_get(:@skip_framework_publish_auto).should == true
      end

      it 'bypasses local hooks for generated version commits' do
        command = Command::Publish.allocate

        command.send(:git_commit_arguments, '100.swift-6.2').should == [
          'commit', '--no-verify', '-m', '[Update] (100.swift-6.2)'
        ]
      end

      it 'recreates existing local and remote tags before publishing a tag' do
        command = Command::Publish.allocate

        command.send(:git_tag_arguments, '100.swift-6.2').should == [
          'tag', '-a', '100.swift-6.2', '-m', '[Update] (100.swift-6.2)'
        ]
        command.send(:git_delete_remote_tag_arguments, '100.swift-6.2').should == [
          'push', '--no-verify', 'origin', ':refs/tags/100.swift-6.2', '--quiet'
        ]
      end

      it 'rebases remote component changes before committing and pushing' do
        command = Command::Publish.allocate
        sequence = sequence('component publish')

        command.expects(:run_project_git!).with('fetch', 'origin', 'main').in_sequence(sequence)
        command.expects(:run_project_git!).with(
          'rebase', '--autostash', 'origin/main'
        ).in_sequence(sequence)
        command.expects(:run_project_git!).with('add', '.').in_sequence(sequence)
        command.expects(:run_project_git!).with(
          'commit', '--no-verify', '-m', '[Update] (101)'
        ).in_sequence(sequence)
        command.expects(:run_project_git!).with(
          'push', '--no-verify', 'origin', 'main', '--quiet'
        ).in_sequence(sequence)

        command.send(:commit_and_push_component_repository!, '101', 'main')
      end

      it 'fetches, rebases, and retries when a component push loses a race' do
        command = Command::Publish.allocate
        calls = []
        push_attempts = 0
        conflict = Informative.new(
          "! [rejected] main -> main (fetch first)\n" \
          'Updates were rejected because the remote contains work.'
        )
        command.define_singleton_method(:run_project_git!) do |*arguments|
          calls << arguments
          if arguments.first == 'push'
            push_attempts += 1
            raise conflict if push_attempts == 1
          end
          ''
        end

        command.send(:push_component_branch_with_retry!, 'main')

        calls.should == [
          ['push', '--no-verify', 'origin', 'main', '--quiet'],
          ['fetch', 'origin', 'main'],
          ['rebase', '--autostash', 'origin/main'],
          ['push', '--no-verify', 'origin', 'main', '--quiet'],
        ]
      end
    end


    describe 'XCFramework artifact validation' do
      before do
        @command = Command::Publish.allocate
        @command.instance_variable_set(:@new_spec_name, 'MyKit')
        @command.instance_variable_set(:@new_version, '101')
      end

      it 'accepts both simulator-capable and device-only manifests' do
        supported = {
          'schema_version' => 1,
          'component' => { 'name' => 'MyKit', 'version' => '101' },
          'artifact' => { 'type' => 'xcframework', 'path' => 'MyKit.xcframework', 'linkage' => 'static' },
          'platforms' => {
            'ios' => {
              'device' => { 'status' => 'supported', 'architectures' => ['arm64'] },
              'simulator' => { 'status' => 'supported', 'architectures' => %w[arm64 x86_64] },
            },
          },
          'debug_symbols' => [],
          'integrity' => { 'validated' => true },
          'distribution' => {
            'zip_file' => 'MyKit-101.zip',
            'sha256' => 'a' * 64,
            'size' => 1024,
          },
        }
        device_only = Marshal.load(Marshal.dump(supported))
        device_only['platforms']['ios']['simulator'] = {
          'status' => 'unavailable',
          'architectures' => [],
        }

        @command.send(:validate_artifact_manifest!, supported).should == supported
        @command.send(:validate_artifact_manifest!, device_only).should == device_only
      end

      it 'rejects a stale sidecar for another artifact version' do
        manifest = {
          'schema_version' => 1,
          'component' => { 'name' => 'MyKit', 'version' => '100' },
          'artifact' => { 'type' => 'xcframework', 'path' => 'MyKit.xcframework', 'linkage' => 'static' },
          'platforms' => {
            'ios' => {
              'device' => { 'status' => 'supported', 'architectures' => ['arm64'] },
              'simulator' => { 'status' => 'unavailable', 'architectures' => [] },
            },
          },
          'debug_symbols' => [],
          'integrity' => { 'validated' => true },
        }

        should.raise Informative do
          @command.send(:validate_artifact_manifest!, manifest)
        end
      end

      it 'rewrites only the primary framework reference' do
        content = <<~SPEC
          s.vendored_frameworks = 'MyKit.framework', 'VendorSDK.framework'
          s.resource_bundles = { 'MyKit' => ['Assets/*'] }
        SPEC

        rewritten = @command.send(
          :rewrite_primary_framework_reference,
          content,
          'MyKit.xcframework'
        )

        rewritten.should.include("'MyKit.xcframework'")
        rewritten.should.include("'VendorSDK.framework'")
        rewritten.should.not.include("'MyKit.framework'")
      end

      it 'removes obsolete architecture overrides while preserving other xcconfig values' do
        content = <<~SPEC
          s.pod_target_xcconfig = {
            'VALID_ARCHS' => 'arm64',
            'ENABLE_BITCODE' => 'NO',
            'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'arm64'
          }
          s.user_target_xcconfig = { 'VALID_ARCHS' => 'arm64' }
        SPEC

        rewritten = @command.send(:remove_legacy_architecture_overrides, content)

        rewritten.should.not.include('VALID_ARCHS')
        rewritten.should.not.include('EXCLUDED_ARCHS')
        rewritten.should.include("'ENABLE_BITCODE' => 'NO'")
        rewritten.should.not.include('user_target_xcconfig')
      end

      it 'verifies that the ready sidecar identifies the remote zip content' do
        manifest = {
          'distribution' => {
            'zip_file' => 'MyKit-101.zip',
            'sha256' => 'a' * 64,
            'size' => 1024,
          },
        }
        @command.stubs(:get_project_id).returns(42)
        @command.expects(:send_request).with(
          Command::Publish::HEAD,
          '/projects/42/repository/files/101%2FMyKit-101.zip',
          { 'ref' => 'main' }
        ).returns(
          'x-gitlab-content-sha256' => 'a' * 64,
          'x-gitlab-size' => '1024'
        )

        @command.send(
          :validate_artifact_zip_identity!,
          manifest,
          'repository/files/101',
          '101'
        ).should == manifest
      end

      it 'rejects a sidecar that is not bound to a zip' do
        manifest = {
          'schema_version' => 1,
          'component' => { 'name' => 'MyKit', 'version' => '101' },
          'artifact' => { 'type' => 'xcframework', 'path' => 'MyKit.xcframework', 'linkage' => 'static' },
          'platforms' => {
            'ios' => {
              'device' => { 'status' => 'supported', 'architectures' => ['arm64'] },
              'simulator' => { 'status' => 'unavailable', 'architectures' => [] },
            },
          },
          'debug_symbols' => [],
          'integrity' => { 'validated' => true },
        }

        should.raise Informative do
          @command.send(:validate_artifact_manifest!, manifest)
        end
      end

      it 'emits one structured capability record per published artifact' do
        manifest = {
          'component' => { 'name' => 'MyKit', 'version' => '101' },
          'platforms' => {
            'ios' => {
              'device' => { 'architectures' => ['arm64'] },
              'simulator' => { 'status' => 'unavailable', 'architectures' => [] },
            },
          },
        }

        record = @command.send(:artifact_capability_record, manifest)

        record.should == {
          'name' => 'MyKit',
          'version' => '101',
          'device' => ['arm64'],
          'simulator' => [],
          'status' => 'device_only',
        }
      end

      it 'loads the sidecar from the same remote version directory as the zip' do
        manifest = {
          'schema_version' => 1,
          'component' => { 'name' => 'MyKit', 'version' => '101' },
        }
        @command.stubs(:get_project_id).returns(42)
        @command.expects(:send_request).with(
          Command::Publish::GET,
          '/projects/42/repository/files/101%2FMyKit-101.artifact.json',
          { 'ref' => 'main' }
        ).returns('content' => Base64.strict_encode64(JSON.generate(manifest)))

        loaded = @command.send(:artifact_manifest_for_version, 'repository/files/101', '101')

        loaded.should == manifest
      end
    end

    describe 'module-stable artifact versions' do
      before do
        @command = Command::Publish.allocate
        attributes = {
          'name' => 'MyKit',
          'version' => '130.swift-6.3.3',
        }
        @command.instance_variable_set(
          :@spec,
          Struct.new(:attributes_hash).new(attributes)
        )
        @command.instance_variable_set(:@increase_version, true)
        @command.instance_variable_set(:@is_version_need_attach_branch, false)
        @command.instance_variable_set(:@beta_version_publish, false)
        @command.instance_variable_set(:@swift_version, '6.4')
      end

      it 'publishes the next version without a Swift compiler suffix' do
        @command.send(:generate_new_version).should == '131'
      end

      it 'removes a legacy Swift suffix before appending artifact metadata' do
        @command.send(:append_version_meta, '131.swift-6.3.3', 'VO-C').should == '131.VO-C'
      end

      it 'removes a legacy Swift suffix before appending subspec metadata' do
        @command.instance_variable_set(:@main_version, '131.swift-6.3.3')
        @command.instance_variable_set(:@current_branch, 'MAIN')

        @command.send(:version_for_subspec, 'Core').should == '131.Core'
      end
    end
  end
end
