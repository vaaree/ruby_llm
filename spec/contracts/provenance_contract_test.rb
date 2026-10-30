# frozen_string_literal: true

# Run without the integration suite: ruby -Ilib spec/contracts/provenance_contract_test.rb
require 'minitest/autorun'
require 'ruby_llm'

class ProvenanceContractTest < Minitest::Test
  def response(body)
    Faraday::Response.new(body:, response_headers: { 'x-request-id' => 'req_provider' })
  end

  def test_responses_identity_is_normalized_without_exposing_raw_response
    protocol = RubyLLM::Protocols::Responses.allocate
    protocol.instance_variable_set(:@model, Struct.new(:id).new('requested'))
    raw = response('id' => 'resp_provider', 'status' => 'completed', 'model' => 'returned', 'output' => [{ 'type' => 'message', 'content' => [{ 'type' => 'output_text', 'text' => 'answer' }] }])
    result = protocol.send(:parse_completion_body, raw.body, raw:)
    assert_equal 'requested', result.requested_model
    assert_equal 'returned', result.model
    assert_equal 'resp_provider', result.response_id
    assert_equal 'req_provider', result.provider_request_id
    restored = RubyLLM::Message.new(result.to_h)
    assert_equal result.response_id, restored.response_id
    assert_equal result.requested_model, restored.requested_model
  end

  def test_unknown_response_identity_and_usage_stay_unknown
    result = RubyLLM::Protocols::Responses.allocate.send(:parse_completion_body,
      { 'status' => 'completed', 'output' => [] }, raw: nil)
    assert_nil result.model
    assert_nil result.requested_model
    assert_nil result.response_id
    assert_nil result.provider_request_id
    assert_nil result.tokens.input
  end

  def test_image_does_not_substitute_requested_model_for_returned_model
    raw = response('data' => [{ 'b64_json' => Base64.strict_encode64('image') }])
    result = RubyLLM::Protocols::ChatCompletions::Images.parse_image_response(raw, model: 'requested')
    assert_equal 'requested', result.requested_model
    assert_nil result.model
    assert_equal 'req_provider', result.provider_request_id
    assert_equal 'image', result.to_blob
    assert_nil result.tokens.input
  end

  def test_embeddings_preserve_returned_and_requested_models_separately
    raw = response('id' => 'emb_provider', 'model' => 'returned', 'data' => [{ 'embedding' => [0.1] }])
    result = RubyLLM::Protocols::ChatCompletions::Embeddings.parse_embedding_response(raw,
      model: 'requested', text: 'input')
    assert_equal 'requested', result.requested_model
    assert_equal 'returned', result.model
    assert_equal 'emb_provider', result.response_id
    assert_equal 'req_provider', result.provider_request_id
    assert_nil result.tokens.input
  end

  def test_judgment_correlation_does_not_require_returned_model
    protocol = RubyLLM::Protocols::OpenAI::Decisions.allocate
    protocol.instance_variable_set(:@model, Struct.new(:id).new('requested'))
    raw = response('id' => 'judge_provider', 'answers' => [])
    result = protocol.parse_judgment_response(raw, questions: {})
    assert_equal 'requested', result.requested_model
    assert_nil result.model
    assert_equal 'judge_provider', result.response_id
    assert_equal 'req_provider', result.provider_request_id
  end

  def test_chat_completions_preserve_provider_ids
    protocol = RubyLLM::Protocols::ChatCompletions.allocate
    raw = response('id' => 'chat_provider', 'choices' => [{ 'message' => { 'content' => 'answer' }, 'finish_reason' => 'stop' }])
    result = protocol.send(:parse_completion_body, raw.body, raw:)
    assert_equal 'chat_provider', result.response_id
    assert_equal 'req_provider', result.provider_request_id
    assert_nil result.model
  end
end
