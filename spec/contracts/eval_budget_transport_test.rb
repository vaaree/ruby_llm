# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'ruby_llm'
require 'ruby_llm/transport/eval_budget_middleware'

class EvalBudgetTransportTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @saved = RubyLLM::EvalBudget::ENV_KEYS.to_h { |key| [key, ENV[key]] }
    ENV['RUBYLLM_EVAL_MAX_USD'] = '0.1'
    ENV['RUBYLLM_EVAL_LEDGER_PATH'] = File.join(@dir, 'ledger.json')
    ENV['RUBYLLM_EVAL_MAX_OUTPUT_TOKENS'] = '100'
  end

  def teardown
    @saved.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    FileUtils.remove_entry(@dir)
  end

  def connection(&block)
    stubs = Faraday::Adapter::Test::Stubs.new(&block)
    Faraday.new('https://api.openai.com') do |f|
      f.request :retry, max: 1, interval: 0, methods: [:post], exceptions: [Faraday::ConnectionFailed]
      f.use :llm_eval_budget
      f.request :json
      f.adapter :test, stubs
    end
  end

  def test_each_retry_reserves_before_transport_and_caps_payload
    calls = []
    conn = connection do |stub|
      stub.post('/v1/responses') do |env|
        calls << JSON.parse(env.body)
        raise Faraday::ConnectionFailed, 'synthetic failure' if calls.length == 1

        [200, {}, '{}']
      end
    end
    conn.post('/v1/responses', model: 'gpt-5.6-luna', input: 'synthetic', max_output_tokens: 500)
    assert_equal 2, calls.length
    assert calls.all? { |row| row['max_output_tokens'] == 100 }
    assert_equal 2, JSON.parse(File.read(ENV.fetch('RUBYLLM_EVAL_LEDGER_PATH'))).fetch('requests').length
  end

  def test_exhausted_budget_prevents_http
    ENV['RUBYLLM_EVAL_MAX_USD'] = '0.000001'
    calls = 0
    conn = connection { |stub| stub.post('/v1/responses') { calls += 1; [200, {}, '{}'] } }
    assert_raises(RubyLLM::EvalBudget::Rejected) do
      conn.post('/v1/responses', model: 'gpt-5.6-luna', input: 'synthetic')
    end
    assert_equal 0, calls
  end
end
