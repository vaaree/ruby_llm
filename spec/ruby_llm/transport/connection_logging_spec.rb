# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Transport::Connection do
  describe 'logging middleware configuration' do
    let(:provider) do
      instance_double(
        RubyLLM::Provider,
        api_base: 'https://example.com',
        configured?: true,
        headers: {}
      )
    end

    let(:config) do
      instance_double(
        RubyLLM::Configuration,
        request_timeout: 300,
        open_timeout: nil,
        request_deadline: nil,
        max_response_bytes: nil,
        log_bodies: false,
        max_retries: 3,
        retry_interval: 0.1,
        retry_max_interval: 30,
        retry_interval_randomness: 0.5,
        retry_backoff_factor: 2,
        http_proxy: nil,
        log_regexp_timeout: 1.0,
        faraday_adapter: :net_http
      )
    end

    it 'disables body logging when log level is above DEBUG' do
      logger = Logger.new(File::NULL, level: Logger::INFO)
      allow(RubyLLM).to receive(:logger).and_return(logger)

      connection = described_class.new(provider, config).connection
      handler = connection.builder.handlers.find { |h| h.klass == Faraday::Response::Logger }
      middleware = handler.build(->(_env) { Faraday::Response.new })
      options = middleware.instance_variable_get(:@formatter).instance_variable_get(:@options)

      expect(options[:bodies]).to be(false)
    end

    it 'enables body logging only when explicitly configured' do
      allow(config).to receive(:log_bodies).and_return(true)
      logger = Logger.new(File::NULL, level: Logger::DEBUG)
      allow(RubyLLM).to receive(:logger).and_return(logger)

      connection = described_class.new(provider, config).connection
      handler = connection.builder.handlers.find { |h| h.klass == Faraday::Response::Logger }
      middleware = handler.build(->(_env) { Faraday::Response.new })
      options = middleware.instance_variable_get(:@formatter).instance_variable_get(:@options)

      expect(options[:bodies]).to be(true)
    end

    it 'keeps bodies private at DEBUG by default' do
      allow(RubyLLM).to receive(:logger).and_return(Logger.new(File::NULL, level: Logger::DEBUG))
      connection = described_class.new(provider, config).connection
      handler = connection.builder.handlers.find { |h| h.klass == Faraday::Response::Logger }
      middleware = handler.build(->(_env) { Faraday::Response.new })
      options = middleware.instance_variable_get(:@formatter).instance_variable_get(:@options)

      expect(options[:bodies]).to be(false)
    end

    it 'uses the configured Faraday adapter' do
      allow(config).to receive(:faraday_adapter).and_return(:test)

      connection = described_class.new(provider, config).connection

      expect(connection.builder.adapter).to eq(Faraday::Adapter::Test)
    end
  end
end
