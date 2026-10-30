# frozen_string_literal: true

require 'faraday'
require 'timeout'

module RubyLLM
  module Transport
    class RequestBounds < Faraday::Middleware # :nodoc:
      CONTEXT_KEY = :ruby_llm_request_bounds

      def call(env)
        deadline = env.request.context&.dig(CONTEXT_KEY, :deadline)
        deadline = deadline.call if deadline.respond_to?(:call)
        return @app.call(env) unless deadline

        env.request.context[CONTEXT_KEY][:deadline] = deadline
        remaining = self.class.bound_timeout(env, deadline)
        Timeout.timeout(remaining, DeadlineExceededError, 'HTTP request deadline exceeded') { @app.call(env) }
      end

      def self.bound_timeout(env, deadline)
        return unless deadline

        remaining = Float(deadline) - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise DeadlineExceededError, 'HTTP request deadline exceeded' unless remaining.positive?

        env.request.timeout = [env.request.timeout, remaining].compact.min
        env.request.open_timeout = [env.request.open_timeout, remaining].compact.min
        remaining
      end

      class Response < Faraday::Middleware # :nodoc:
        def call(env)
          RequestBounds.bound_timeout(env, env.request.context&.dig(CONTEXT_KEY, :deadline))
          limit = env.request.context&.dig(CONTEXT_KEY, :max_bytes)
          return @app.call(env) unless limit

          limit = Integer(limit)
          raise ArgumentError, 'max_response_bytes must be positive' unless limit.positive?

          callback = env.request.on_data
          body = +'' unless callback
          env.request.on_data = bounded_callback(callback, body, limit)
          @app.call(env).on_complete { |response| complete_response(response, body, limit) }
        ensure
          env.request.on_data = callback if limit
        end

        private

        def bounded_callback(callback, body, limit)
          received = 0
          lambda do |chunk, *arguments|
            received += chunk.bytesize
            check_size(received, limit)
            callback ? callback.call(chunk, *arguments) : body << chunk
          end
        end

        def complete_response(response, body, limit)
          response.body = body if body && !body.empty?
          check_size(response.body.bytesize, limit) if response.body.respond_to?(:bytesize)
        end

        def check_size(size, limit)
          raise ResponseTooLargeError, 'HTTP response exceeded max_response_bytes' if size > limit
        end
      end
    end
  end
end
