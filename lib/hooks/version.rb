module Pod
  class Version
    alias origin_prerelease? prerelease?

    def prerelease?
      return nil if @version.include?('.swift')

      origin_prerelease?
    end
  end
end
