# frozen_string_literal: true

require 'faraday'
require 'json'

module RubyLLM
  module Transport
    # Inside retry middleware: reserve before each physical provider attempt.
    class EvalBudgetMiddleware < Faraday::Middleware
      def call(env)
        budget = EvalBudget.from_env
        return @app.call(env) unless budget
        return @app.call(env) if env.method == :get || env.method == :delete

        unless env.url.scheme == 'https' && %w[api.openai.com generativelanguage.googleapis.com].include?(env.url.host)
          raise EvalBudget::Rejected, 'Eval endpoint has no verified pricing'
        end
        body = env.body
        body = JSON.parse(body) if body.is_a?(String)
        raise EvalBudget::Rejected, 'Unsupported eval request body' unless body.is_a?(Hash)

        payload = budget.prepare(path: env.url.path, payload: body)
        budget.reserve!(path: env.url.path, payload: payload)
        env.body = payload
        @app.call(env)
      rescue JSON::ParserError, JSON::GeneratorError, TypeError
        raise EvalBudget::Rejected, 'Invalid eval request body', cause: nil
      end
    end
  end
end

Faraday::Middleware.register_middleware(llm_eval_budget: RubyLLM::Transport::EvalBudgetMiddleware)
