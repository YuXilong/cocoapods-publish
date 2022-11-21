module Pod
  class Command
    class Clean < Install
      self.summary = 'Install时清除缓存. 参数同Install命令'

      def initialize(argv); end

      def validate!; end

      def run
        Config.instance.clean_before_install = true
        argv = ARGV.to_ary.select! {|s| !s.eql?("install") && !s.eql?("clean")}
        command = Install.new(CLAide::ARGV.coerce(argv))
        command.run
      end
    end
  end
end

module Pod
  class Config
    # 安装前清除缓存
    attr_accessor :clean_before_install
  end
end

module Pod
  class Installer
    class PodSourceDownloader
      UNENCRYPTED_PROTOCOLS = %w(git).freeze
    end
  end
end

