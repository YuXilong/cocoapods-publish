require File.expand_path('../../spec_helper', __FILE__)

module Pod
  describe Command::Publish do
    describe 'CLAide' do
      it 'registers it self' do
        Command.parse(%w{ publish }).should.be.instance_of Command::Publish
      end
    end
  end
end

