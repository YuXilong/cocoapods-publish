# frozen_string_literal: true

require File.expand_path('../spec_helper', __dir__)

module Pod
  describe Command::Install do
    it 'registers the short precheck option' do
      option_names = Command::Install.options.map(&:first)

      option_names.should.include '--precheck'
    end

    it 'keeps dependency precheck disabled by default' do
      command = Command.parse(%w[install])

      command.instance_variable_get(:@precheck_dependencies).should.equal false
    end

    it 'enables dependency precheck with --precheck' do
      command = Command.parse(%w[install --precheck])

      command.instance_variable_get(:@precheck_dependencies).should.equal true
    end

    it 'passes the precheck setting to the installer' do
      command = Command.parse(%w[install --precheck])
      installer = mock

      Installer.stubs(:new).returns(installer)
      installer.expects(:precheck_dependencies=).with(true)

      command.send(:installer_for_config).should.equal installer
    end
  end
end
