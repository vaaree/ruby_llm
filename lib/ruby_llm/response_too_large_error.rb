# frozen_string_literal: true

module RubyLLM
  # An HTTP response exceeded the configured byte limit.
  class ResponseTooLargeError < Error
  end
end
