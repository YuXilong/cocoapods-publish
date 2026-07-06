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
  end
end
