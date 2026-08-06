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

        command.send(:git_commit_command, '100.swift-6.2').
          should == 'git commit --no-verify -m "[Update] (100.swift-6.2)"'
      end

      it 'recreates existing local and remote tags before publishing a tag' do
        command = Command::Publish.allocate

        command.send(:git_recreate_tag_commands, '100.swift-6.2').should == [
          '(git tag -d 100.swift-6.2 >/dev/null 2>&1 || true)',
          'git tag -a 100.swift-6.2 -m "[Update] (100.swift-6.2)"',
        ]
        command.send(:git_delete_remote_tag_command, '100.swift-6.2').
          should == '(git push --no-verify origin :refs/tags/100.swift-6.2 --quiet >/dev/null 2>&1 || true)'
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
  end
end
