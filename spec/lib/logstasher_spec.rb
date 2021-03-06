require 'spec_helper'

describe LogStasher do
  describe "when removing Rails' log subscribers" do
    after do
      ActionController::LogSubscriber.attach_to :action_controller
      ActionView::LogSubscriber.attach_to :action_view
      ActionMailer::LogSubscriber.attach_to :action_mailer
    end

    it "should remove subscribers for controller events" do
      expect {
        LogStasher.remove_existing_log_subscriptions
      }.to change {
        ActiveSupport::Notifications.notifier.listeners_for('process_action.action_controller')
      }
    end

    it "should remove subscribers for all events" do
      expect {
        LogStasher.remove_existing_log_subscriptions
      }.to change {
        ActiveSupport::Notifications.notifier.listeners_for('render_template.action_view')
      }
    end

    it "should remove subscribsers for mailer events" do
      expect {
        LogStasher.remove_existing_log_subscriptions
      }.to change {
        ActiveSupport::Notifications.notifier.listeners_for('deliver.action_mailer')
      }
    end

    it "shouldn't remove subscribers that aren't from Rails" do
      blk = -> {}
      ActiveSupport::Notifications.subscribe("process_action.action_controller", &blk)
      LogStasher.remove_existing_log_subscriptions
      listeners = ActiveSupport::Notifications.notifier.listeners_for('process_action.action_controller')
      expect(listeners).to_not be_empty
    end
  end

  describe '.appened_default_info_to_payload' do
    let(:params)  { {'a' => '1', 'b' => 2, 'action' => 'action', 'controller' => 'test'}.with_indifferent_access }
    let(:payload) { {:params => params} }
    let(:request) { double(:params => params, :remote_ip => '10.0.0.1', :env => {})}
    after do
      LogStasher.custom_fields = []
      LogStasher.log_controller_parameters = false
    end
    it 'appends default parameters to payload' do
      LogStasher.log_controller_parameters = true
      LogStasher.custom_fields = []
      LogStasher.add_default_fields_to_payload(payload, request)
      expect(payload[:ip]).to eq '10.0.0.1'
      expect(payload[:route]).to eq 'test#action'
      expect(payload[:parameters]).to eq 'a' => '1', 'b' => 2
      expect(LogStasher.custom_fields).to eq [:ip, :route, :request_id, :parameters]
    end

    it 'does not include parameters when not configured to' do
      LogStasher.custom_fields = []
      LogStasher.add_default_fields_to_payload(payload, request)
      expect(payload).to_not have_key(:parameters)
      expect(LogStasher.custom_fields).to eq [:ip, :route, :request_id]
    end
  end

  describe '.append_custom_params' do
    let(:block) { ->(_, _){} }
    it 'defines a method in ActionController::Base' do
      expect(ActionController::Base).to receive(:send).with(:define_method, :logtasher_add_custom_fields_to_payload, &block)
      LogStasher.add_custom_fields(&block)
    end
  end

  describe '.add_custom_fields_to_request_context' do
    let(:block) { ->(_, _){} }
    it 'defines a method in ActionController::Base' do
      expect(ActionController::Base).to receive(:send).with(:define_method, :logstasher_add_custom_fields_to_request_context, &block)
      expect(ActionController::Metal).to receive(:send).with(:define_method, :logstasher_add_custom_fields_to_request_context, &block)
      LogStasher.add_custom_fields_to_request_context(&block)
    end
  end

  describe '.add_default_fields_to_request_context' do
    it 'adds a request_id to the request context' do
      LogStasher.clear_request_context
      LogStasher.add_default_fields_to_request_context(double(env: {'action_dispatch.request_id' => 'lol'}))
      expect(LogStasher.request_context).to eq({ request_id: 'lol' })
    end
  end

  shared_examples 'setup' do
    let(:logstasher_source) { nil }
    let(:logstasher_config) { double(:logger => logger, :log_level => 'warn', :log_controller_parameters => nil, :source => logstasher_source, :logger_path => logger_path) }
    let(:config) { double(:logstasher => logstasher_config) }
    let(:app) { double(:config => config) }
    before do
      @previous_source = LogStasher.source
      allow(config).to receive_messages(:action_dispatch => double(:rack_cache => false))
      allow_message_expectations_on_nil
    end
    after { LogStasher.source = @previous_source } # Need to restore old source for specs
    it 'defines a method in ActionController::Base' do
      expect(LogStasher).to receive(:require).with('logstasher/rails_ext/action_controller/metal/instrumentation')
      expect(LogStasher).to receive(:require).with('logstash-event')
      expect(LogStasher).to receive(:suppress_app_logs).with(app)
      expect(LogStasher::RequestLogSubscriber).to receive(:attach_to).with(:action_controller)
      expect(LogStasher::MailerLogSubscriber).to receive(:attach_to).with(:action_mailer)
      expect(logger).to receive(:level=).with('warn')
      LogStasher.setup(app)
      expect(LogStasher.source).to eq (logstasher_source || 'unknown')
      expect(LogStasher).to be_enabled
      expect(LogStasher.custom_fields).to be_empty
      expect(LogStasher.log_controller_parameters).to eq false
    end
  end

  describe '.setup' do
    let(:logger) { double }
    let(:logger_path) { nil }

    describe 'with source set' do
      let(:logstasher_source) { 'foo' }
      it_behaves_like 'setup'
    end

    describe 'without source set (default behaviour)' do
      let(:logstasher_source) { nil }
      it_behaves_like 'setup'
    end

    describe 'with customized logging' do
      let(:logger) { nil }

      context 'with no logger passed in' do
        before { expect(LogStasher).to receive(:new_logger).with('/log/logstash_test.log') }
        it_behaves_like 'setup'
      end

      context 'with custom logger path passed in' do
        let(:logger_path) { double }

        before { expect(LogStasher).to receive(:new_logger).with(logger_path) }
        it_behaves_like 'setup'
      end
    end
  end

  describe '.suppress_app_logs' do
    let(:logstasher_config){ double(:logstasher => double(:suppress_app_log => true))}
    let(:app){ double(:config => logstasher_config)}
    it 'removes existing subscription if enabled' do
      expect(LogStasher).to receive(:require).with('logstasher/rails_ext/rack/logger')
      expect(LogStasher).to receive(:remove_existing_log_subscriptions)
      LogStasher.suppress_app_logs(app)
    end

    context 'when disabled' do
      let(:logstasher_config){ double(:logstasher => double(:suppress_app_log => false)) }
      it 'does not remove existing subscription' do
        expect(LogStasher).to_not receive(:remove_existing_log_subscriptions)
        LogStasher.suppress_app_logs(app)
      end

      describe "backward compatibility" do
        context 'with spelling "supress_app_log"' do
          let(:logstasher_config){ double(:logstasher => double(:suppress_app_log => nil, :supress_app_log => false)) }
          it 'does not remove existing subscription' do
            expect(LogStasher).to_not receive(:remove_existing_log_subscriptions)
            LogStasher.suppress_app_logs(app)
          end
        end
      end
    end
  end

  describe '.appended_params' do
    it 'returns the stored var in current thread' do
      Thread.current[:logstasher_custom_fields] = :test
      expect(LogStasher.custom_fields).to eq :test
    end
  end

  describe '.appended_params=' do
    it 'returns the stored var in current thread' do
      LogStasher.custom_fields = :test
      expect(Thread.current[:logstasher_custom_fields]).to eq :test
    end
  end

  describe '.log' do
    let(:logger) { double() }
    before do
      LogStasher.logger = logger
      allow(Time).to receive_messages(:now => Time.at(0))
      allow_message_expectations_on_nil
    end
    it 'adds to log with specified level' do
      expect(logger).to receive(:send).with('warn?').and_return(true)
      expect(logger).to receive(:send).with('warn',"{\"source\":\"unknown\",\"message\":\"WARNING\",\"level\":\"warn\",\"tags\":[\"log\"],\"@timestamp\":\"1970-01-01T00:00:00Z\",\"@version\":\"1\"}")
      LogStasher.log('warn', 'WARNING')
    end
    context 'with a source specified' do
      before :each do
        LogStasher.source = 'foo'
      end
      it 'sets the correct source' do
        expect(logger).to receive(:send).with('warn?').and_return(true)
        expect(logger).to receive(:send).with('warn',"{\"source\":\"foo\",\"message\":\"WARNING\",\"level\":\"warn\",\"tags\":[\"log\"],\"@timestamp\":\"1970-01-01T00:00:00Z\",\"@version\":\"1\"}")
        LogStasher.log('warn', 'WARNING')
      end
    end
  end

  %w( fatal error warn info debug unknown ).each do |severity|
    describe ".#{severity}" do
      let(:message) { "This is a #{severity} message" }
      it 'should log with specified level' do
        expect(LogStasher).to receive(:log).with(severity.to_sym, message)
        LogStasher.send(severity, message )
      end
    end
  end

  describe '.store' do
    it "returns a new Hash for each key" do
      expect(LogStasher.store['a'].object_id).to_not be(LogStasher.store['b'].object_id)
    end

    it "returns the same store if called several time with the same key" do
      expect(LogStasher.store['a'].object_id).to be(LogStasher.store['a'].object_id)
    end

  end

  describe ".watch" do
    before(:each) { LogStasher.custom_fields = [] }

    it "subscribes to the required event" do
      expect(ActiveSupport::Notifications).to receive(:subscribe).with('event_name')
      LogStasher.watch('event_name')
    end

    it 'executes the block when receiving an event' do
      probe = lambda {}
      LogStasher.watch('custom.event.foo', &probe)
      expect(probe).to receive(:call)
      ActiveSupport::Notifications.instrument('custom.event.foo', {})
    end

    describe "store" do
      it 'stores the events in a store with the event\'s name' do
        probe = lambda { |*args, store| store[:foo] = :bar }
        LogStasher.watch('custom.event.bar', &probe)
        ActiveSupport::Notifications.instrument('custom.event.bar', {})
        expect(LogStasher.store['custom.event.bar']).to eq :foo => :bar
      end
    end
  end
end
