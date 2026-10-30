# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'ruby_llm'

class EvalBudgetContractTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @path = File.join(@directory, 'ledger.json')
    @budget = RubyLLM::EvalBudget.new(max_usd: '0.02', ledger_path: @path, output_cap: '100')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def payload
    {model: 'gpt-5.6-luna', input: 'synthetic', max_output_tokens: 300}
  end

  def test_caps_output_and_reserves_durably_without_prompt_content
    request = @budget.prepare(path: '/v1/responses', payload: payload)
    assert_equal 100, request.fetch('max_output_tokens')
    @budget.reserve!(path: '/v1/responses', payload: request)
    saved = JSON.parse(File.read(@path))
    assert_operator saved.fetch('reserved_microusd'), :>, 0
    refute_includes File.read(@path), 'synthetic'
    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert_equal 1, saved.fetch('requests').length
  end

  def test_restored_reservations_cannot_be_reset_by_larger_allowance
    request = @budget.prepare(path: '/v1/responses', payload: payload)
    @budget.reserve!(path: '/v1/responses', payload: request)
    restored = RubyLLM::EvalBudget.new(max_usd: '100', ledger_path: @path, output_cap: '100')
    assert_raises(RubyLLM::EvalBudget::Rejected) do
      100.times { restored.reserve!(path: '/v1/responses', payload: request) }
    end
    assert_operator JSON.parse(File.read(@path)).fetch('reserved_microusd'), :<=, 20_000
  end

  def test_unknown_pricing_and_hidden_context_fail_before_reservation
    assert_raises(RubyLLM::EvalBudget::Rejected) { @budget.prepare(path: '/v1/responses', payload: payload.merge(model: 'unknown')) }
    assert_raises(RubyLLM::EvalBudget::Rejected) { @budget.prepare(path: '/v1/responses', payload: payload.merge(previous_response_id: 'hidden')) }
    refute File.exist?(@path)
  end

  def test_concurrent_attempts_cannot_overspend
    request = @budget.prepare(path: '/v1/responses', payload: payload)
    threads = 30.times.map do
      Thread.new do
        @budget.reserve!(path: '/v1/responses', payload: request)
      rescue RubyLLM::EvalBudget::Rejected
        nil
      end
    end
    threads.each(&:value)
    saved = JSON.parse(File.read(@path))
    assert_operator saved.fetch('reserved_microusd'), :<=, 20_000
    assert_equal saved.fetch('reserved_microusd'), saved.fetch('requests').sum { |r| r.fetch('reserved_microusd') }
  end
end
