# frozen_string_literal: true

require File.expand_path('../spec_helper', __dir__)

module Pod
  describe Command::Repo::Push::PushWithoutValid do
    before do
      @command = Command::Repo::Push::PushWithoutValid.allocate
    end

    it 'updates a private Specs repo with rebase before adding a spec' do
      sequence = sequence('specs update')

      @command.expects(:repo_git)
              .with('rev-parse', '--abbrev-ref', 'HEAD')
              .in_sequence(sequence).returns("main\n")
      @command.expects(:repo_git)
              .with('pull', '--rebase', 'origin', 'main')
              .in_sequence(sequence)

      @command.send(:update_repo)
    end

    it 'rebases and retries when a private Specs push loses a race' do
      calls = []
      push_attempts = 0
      conflict = Informative.new(
        "! [rejected] HEAD -> main (non-fast-forward)\n" \
        'failed to push some refs'
      )
      @command.define_singleton_method(:repo_git) do |*arguments|
        calls << arguments
        if arguments.first == 'push'
          push_attempts += 1
          raise conflict if push_attempts == 1
        end
        return "main\n" if arguments.first == 'rev-parse'

        ''
      end

      @command.send(:push_repo)

      calls.should == [
        %w[push origin HEAD],
        ['rev-parse', '--abbrev-ref', 'HEAD'],
        ['pull', '--rebase', 'origin', 'main'],
        %w[push origin HEAD]
      ]
    end

    it 'does not retry authentication failures' do
      failure = Informative.new('Authentication failed for private Specs repo')

      @command.expects(:repo_git)
              .with('push', 'origin', 'HEAD')
              .raises(Informative, failure.message)
      @command.expects(:repo_git).with('pull', '--rebase', 'origin', 'main').never

      error = should.raise(Informative) { @command.send(:push_repo) }
      error.message.should.include('Authentication failed')
    end
  end
end
