# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Transport::RequestBounds do
  let(:config) do
    RubyLLM::Configuration.new.tap do |settings|
      settings.openai_api_key = 'test-key'
      settings.retry_interval_randomness = 0
    end
  end
  let(:provider) { RubyLLM::Providers::OpenAI.new(config) }
  let(:url) { 'https://api.openai.com/v1/chat/completions' }

  def deadline(seconds)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  end

  it 'rejects an expired deadline without making an HTTP request' do
    config.request_deadline = deadline(-1)
    request = stub_request(:post, url).to_return(body: '{}')

    expect { provider.connection.post('chat/completions', {}) }.to raise_error(RubyLLM::DeadlineExceededError)
    expect(request).not_to have_been_requested
  end

  it 'bounds connection and response timeouts by the remaining deadline' do
    config.request_deadline = -> { deadline(0.5) }
    config.open_timeout = 0.2
    observed = nil
    stub_request(:post, url).to_return(body: '{}')

    provider.connection.post('chat/completions', {}) do |request|
      observed = request.options
    end

    expect(observed.timeout).to be_between(0, 0.5)
    expect(observed.open_timeout).to eq(0.2)
  end

  it 'includes retry delays in the absolute deadline' do
    config.request_deadline = deadline(0.05)
    config.retry_interval = 1
    request = stub_request(:post, url).to_return(status: 503, body: '{}')

    expect { provider.connection.post('chat/completions', {}) }.to raise_error(RubyLLM::DeadlineExceededError)
    expect(request).to have_been_requested.once
  end

  it 'rejects an oversized nonstreamed response' do
    config.max_response_bytes = 4
    stub_request(:post, url).to_return(body: 'oversized')

    expect { provider.connection.post('chat/completions', {}) }.to raise_error(RubyLLM::ResponseTooLargeError)
  end

  it 'keeps JSON response parsing with a byte limit' do
    config.max_response_bytes = 50
    stub_request(:post, url).to_return(body: '{"ok":true}', headers: { 'Content-Type' => 'application/json' })

    expect(provider.connection.post('chat/completions', {}).body).to eq('ok' => true)
  end

  it 'reassembles bounded nonstreamed chunks before response parsing' do
    app = lambda do |env|
      env.request.on_data.call('{"ok":', 6)
      env.request.on_data.call('true}', 11)
      Faraday::Response.new(env.tap { |value| value.body = '' })
    end
    options = Faraday::RequestOptions.new
    options.context = { described_class::CONTEXT_KEY => { max_bytes: 20 } }
    env = Faraday::Env.new.tap { |value| value.request = options }

    expect(described_class::Response.new(app).call(env).body).to eq('{"ok":true}')
    expect(options.on_data).to be_nil
  end

  it 'counts streamed bytes before delivering an oversized chunk' do
    app = lambda do |env|
      env.request.on_data.call('ab', 2)
      env.request.on_data.call('cde', 5)
    end
    delivered = []
    options = Faraday::RequestOptions.new
    options.context = { described_class::CONTEXT_KEY => { max_bytes: 4 } }
    options.on_data = ->(chunk, _size) { delivered << chunk }
    env = Faraday::Env.new.tap { |value| value.request = options }

    expect { described_class::Response.new(app).call(env) }.to raise_error(RubyLLM::ResponseTooLargeError)
    expect(delivered).to eq(['ab'])
  end
end
