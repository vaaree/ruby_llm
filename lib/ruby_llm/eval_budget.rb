# frozen_string_literal: true

module RubyLLM
  # Opt-in eval reservations survive failures and missing provider usage. The
  # shared ledger counts upper bounds, never an assertion of actual billing.
  class EvalBudget
    include EvalBudgetMedia
    class Rejected < Error; end
    PRICING_VERSION = "openai-2026-10-29".freeze
    # Standard, uncached USD per million tokens. Unsupported models fail closed.
    RATES = {
      "gpt-5.4-mini-2026-03-17" => [0.75, 4.5], "gpt-5.4-mini" => [0.75, 4.5],
      "gpt-5.1" => [1.25, 10], "gpt-5.2" => [1.75, 14],
      "gpt-6.1-sol" => [2, 10], "gpt-5.6-luna" => [0.2, 1.2],
      "gpt-5.6-terra" => [2, 12], "gpt-5.6-sol" => [4, 20],
      "gpt-5-mini" => [0.25, 2], "gpt-6-luna" => [0.1, 0.5]
    }.freeze
    TEXT_PATHS = %w[/v1/responses /v1/chat/completions].freeze
    EMBEDDING_RATES = { "text-embedding-3-large" => 0.13 }.freeze
    ENV_KEYS = %w[RUBYLLM_EVAL_MAX_USD RUBYLLM_EVAL_LEDGER_PATH RUBYLLM_EVAL_MAX_OUTPUT_TOKENS].freeze
    attr_reader :output_cap

    def self.from_env
      return nil unless ENV_KEYS.any? { |key| ENV.key?(key) }
      new(max_usd: ENV.fetch(ENV_KEYS[0]), ledger_path: ENV.fetch(ENV_KEYS[1]),
        output_cap: ENV.fetch(ENV_KEYS[2], "2048"))
    rescue KeyError
      raise ConfigurationError, "Eval budget requires maximum USD and a shared ledger path"
    end

    def initialize(max_usd:, ledger_path:, output_cap:)
      raise ConfigurationError, "Invalid eval budget configuration" unless max_usd.is_a?(String) && max_usd.match?(/\A(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/)
      amount = Rational(max_usd)
      @max_microusd = (amount * 1_000_000).floor
      @output_cap = Integer(output_cap, 10)
      @ledger_path = ledger_path
      unless amount.positive? && @max_microusd.positive? &&
          output_cap.match?(/\A[1-9][0-9]*\z/) && @output_cap <= 128_000 &&
          ledger_path.is_a?(String) && ledger_path.start_with?("/") && !ledger_path.include?("\0")
        raise ConfigurationError, "Invalid eval budget configuration"
      end
    rescue ArgumentError, TypeError, NoMethodError
      raise ConfigurationError, "Invalid eval budget configuration"
    end

    def prepare(path:, payload:)
      body = JSON.parse(JSON.generate(payload))
      raise Rejected, "Unsupported eval request" unless body.is_a?(Hash)
      return prepare_media(path, body) if path.start_with?("/v1/images/") || path == "/v1beta/interactions"
      if TEXT_PATHS.include?(path)
        reject_unbounded_context!(body)
        raise Rejected, "Eval supports one completion" if body.key?("n") && body["n"] != 1
        rate!(body.fetch("model", nil))
        key = path == "/v1/chat/completions" ? "max_completion_tokens" : "max_output_tokens"
        limits = [output_cap]
        [key, "max_tokens"].each do |field|
          next unless body.key?(field)
          value = body[field]
          raise Rejected, "Invalid eval output limit" unless value.is_a?(Integer) && value.positive?
          limits << value
        end
        body.delete("max_tokens")
        body[key] = limits.min
        body["service_tier"] = "default"
      elsif path == "/v1/decisions"
        reject_unbounded_context!(body)
        raise Rejected, "Unsupported eval Decisions model" unless body["model"] == "gpt-6-luna"
        raise Rejected, "Bounded choice questions required" unless body["questions"].is_a?(Array) && (1..10).cover?(body["questions"].length) && body["questions"].all? { |q| q["type"] == "choice" && q["choices"].is_a?(Array) && (1..32).cover?(q["choices"].length) }
      elsif path == "/v1/embeddings"
        raise Rejected, "Unsupported eval embedding model" unless EMBEDDING_RATES.key?(body["model"])
        input = body["input"]
        unless input.is_a?(String) || (input.is_a?(Array) && input.all? { |item| item.is_a?(String) })
          raise Rejected, "Eval embeddings require text inputs"
        end
      else
        raise Rejected, "Unsupported eval capability"
      end
      reservation(path, body)
      body
    end

    def reserve!(path:, payload:)
      charge = reservation(path, JSON.parse(JSON.generate(payload)))
      flags = File::RDWR | File::CREAT | File::NOFOLLOW
      File.open(@ledger_path, flags, 0600) do |file|
        file.flock(File::LOCK_EX)
        stat = file.stat
        unless stat.file? && stat.uid == Process.uid && (stat.mode & 0777) == 0600 && stat.nlink == 1
          raise Rejected, "Eval ledger must be a private regular file"
        end
        data = file.size.zero? ? {"version" => 1, "max_microusd" => @max_microusd, "reserved_microusd" => 0, "requests" => []} : JSON.parse(file.read)
        validate_ledger!(data)
        maximum = [@max_microusd, data.fetch("max_microusd")].min
        reserved = data.fetch("reserved_microusd") + charge.fetch(:cost_microusd)
        raise Rejected, "Eval budget exhausted before provider attempt" if reserved > maximum
        data["max_microusd"] = maximum
        data["reserved_microusd"] = reserved
        data.fetch("requests") << {"model" => charge.fetch(:model), "endpoint" => path,
          "reserved_microusd" => charge.fetch(:cost_microusd), "pricing_version" => PRICING_VERSION}
        file.rewind
        file.write(JSON.generate(data))
        file.truncate(file.pos)
        file.flush
        file.fsync
      end
      charge.fetch(:cost_microusd)
    rescue SystemCallError, IOError, JSON::ParserError
      raise Rejected, "Eval ledger is unavailable or invalid", cause: nil
    end

    private

    def reservation(path, body)
      return media_reservation(path, body) if path.start_with?("/v1/images/") || path == "/v1beta/interactions"
      model = body.fetch("model")
      # Serialized UTF-8 bytes bound text tokenization, including schemas and
      # message framing; restrict to short context to avoid long-context rates.
      input_tokens = JSON.generate(body).bytesize + 4096
      raise Rejected, "Eval request exceeds short-context budget contract" if input_tokens > 200_000
      if path == "/v1/decisions"
        cost = input_tokens * Rational("0.1")
      elsif path == "/v1/embeddings"
        cost = input_tokens * Rational(EMBEDDING_RATES.fetch(model).to_s)
      else
        input_rate, output_rate = rate!(model)
        input_tokens += vision_input_tokens(body, model) if media?(body)
        raise Rejected, "Eval request exceeds short-context budget contract" if input_tokens > 200_000
        key = path == "/v1/chat/completions" ? "max_completion_tokens" : "max_output_tokens"
        cost = input_tokens * Rational(input_rate.to_s) + body.fetch(key) * Rational(output_rate.to_s)
      end
      {model: model, cost_microusd: (cost * 2).ceil}
    end

    def rate!(model)
      RATES.fetch(model) { raise Rejected, "Unsupported eval model pricing" }
    end

    def reject_unbounded_context!(body)
      if body["previous_response_id"] || body["conversation"] || body["prompt"] ||
          (body["tools"] && !(body["tools"].is_a?(Array) && body["tools"].all? { |tool| tool.is_a?(Hash) && tool["type"] == "function" })) || body["modalities"] || body["audio"]
        raise Rejected, "Eval request contains unbounded context or tool costs"
      end
    end

    def media?(node)
      case node
      when Hash
        node.any? { |key, value| %w[image_url file_id file_data audio video].include?(key) ||
          (key == "type" && %w[input_image image_url input_file input_audio video].include?(value)) || media?(value) }
      when Array then node.any? { |value| media?(value) }
      else false
      end
    end

    def validate_ledger!(data)
      unless data.is_a?(Hash) && data["version"] == 1 &&
          data["max_microusd"].is_a?(Integer) && data["max_microusd"].positive? &&
          data["reserved_microusd"].is_a?(Integer) && data["reserved_microusd"] >= 0 &&
          data["requests"].is_a?(Array) && data["requests"].all? { |row| row.is_a?(Hash) && row["reserved_microusd"].is_a?(Integer) && row["reserved_microusd"].positive? } &&
          data["requests"].sum { |row| row.fetch("reserved_microusd") } == data["reserved_microusd"]
        raise Rejected, "Eval ledger is invalid"
      end
    end
  end
end
