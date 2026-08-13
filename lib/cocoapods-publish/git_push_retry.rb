# frozen_string_literal: true

module Pod
  # Identifies remote-advance failures that are safe to recover with rebase.
  module GitPushRetry
    MAX_GIT_PUSH_ATTEMPTS = 3
    GIT_PUSH_CONFLICT_PATTERNS = [
      /non-fast-forward/i,
      /\[rejected\].*(?:fetch first|remote contains work)/im,
      /updates were rejected because the remote contains work/i,
      %r{could not update refs/heads/.*refresh and try again}i,
      %r{cannot lock ref ['"]refs/heads/}i
    ].freeze

    private

    def retryable_git_push_error?(error)
      message = error.message.to_s
      GIT_PUSH_CONFLICT_PATTERNS.any? { |pattern| message.match?(pattern) }
    end

    def retry_git_push?(error, attempts)
      attempts < MAX_GIT_PUSH_ATTEMPTS && retryable_git_push_error?(error)
    end
  end
end
