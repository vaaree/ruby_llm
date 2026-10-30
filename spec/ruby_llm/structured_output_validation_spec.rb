# frozen_string_literal: true

require 'rspec/core'
require 'rspec/expectations'
require 'rspec/mocks'
require 'ruby_llm'

RSpec.describe RubyLLM::Chat do
  let(:schema) do
    { type: 'object', additionalProperties: false, required: %w[decision count],
      properties: { decision: { type: 'string', enum: %w[approve hold] }, count: { type: 'integer', minimum: 0 } } }
  end
  let(:context) { RubyLLM.context { |config| config.openai_api_key = 'offline-test' } }
  let(:chat) { context.chat(model: 'test-model', provider: :openai, assume_model_exists: true).with_schema(schema) }

  def result(content, finish_reason: :stop)
    RubyLLM::Message.new(role: :assistant, content: content, finish_reason: finish_reason, input_tokens: 12)
  end

  it 'returns a complete schema-valid output without changing its content' do
    response = result('{"decision":"approve","count":1}')
    allow(chat).to receive(:provider_completion).and_return(response)
    expect(chat.ask('private input')).to equal(response)
    expect(response.parsed).to eq('decision' => 'approve', 'count' => 1)
  end

  [ '{"decision":"maybe","count":1}', '{"decision":"hold"}',
    '{"decision":"hold","count":"1"}', '{"decision":"hold","count":-1}',
    '{"decision":"hold","count":1,"extra":true}', 'null', '[]', 'private malformed response' ].each do |content|
    it "rejects invalid structured output #{content.inspect} with safe errors and retained usage" do
      response = result(content)
      allow(chat).to receive(:provider_completion).and_return(response)
      expect { chat.ask('private input') }.to raise_error(RubyLLM::StructuredOutputError) { |error|
        expect(error.message).to eq('Provider returned invalid structured output')
        expect(error.tokens.input).to eq(12)
        expect(error.message_result).to equal(response)
        expect(chat.messages).not_to include(response)
      }
    end
  end

  [ :max_tokens, :content_filter, :unknown, nil ].each do |finish_reason|
    it "rejects unsuccessful completion #{finish_reason.inspect} even with valid JSON" do
      allow(chat).to receive(:provider_completion).and_return(result('{"decision":"hold","count":1}', finish_reason: finish_reason))
      expect { chat.ask('private input') }.to raise_error(RubyLLM::StructuredOutputError)
    end
  end

  it 'does not enforce structured validation after removing the schema' do
    chat.with_schema(nil)
    response = result('ordinary answer')
    allow(chat).to receive(:provider_completion).and_return(response)
    expect(chat.ask('input')).to equal(response)
  end

  it 'allows tool calls before the final structured answer' do
    response = RubyLLM::Message.new(role: :assistant, content: '', finish_reason: :tool_calls,
                                   tool_calls: { 'call' => RubyLLM::ToolCall.new(id: 'call', name: 'lookup', arguments: {}) })
    allow(chat).to receive(:provider_completion).and_return(response)
    expect(chat.generate).to equal(response)
  end
end
