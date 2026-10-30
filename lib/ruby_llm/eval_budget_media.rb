# frozen_string_literal: true

require "base64"

module RubyLLM
  # Eval-only media bounds. Unknown sources/formats/pricing fail before HTTP.
  module EvalBudgetMedia
    private

    def prepare_media(path, payload)
      if path == "/v1beta/interactions"
        unless payload["model"] == "gemini-3.1-flash-image" && payload["input"].is_a?(String) && payload["input"].bytesize <= 100_000 &&
            payload["response_format"] == {"type" => "image", "aspect_ratio" => "21:9", "image_size" => "2K"} && (payload.keys - %w[model input response_format]).empty?
          raise EvalBudget::Rejected, "Unsupported eval Gemini image contract"
        end
        return payload
      end
      unless %w[/v1/images/generations /v1/images/edits].include?(path) && payload["model"] == "gpt-image-2"
        raise EvalBudget::Rejected, "Unsupported eval image model or endpoint"
      end
      raise EvalBudget::Rejected, "Eval image tools are unsupported" if payload["tools"] || payload["background"] == "transparent"
      raise EvalBudget::Rejected, "Eval supports one output image" unless !payload.key?("n") || payload["n"] == 1
      payload.merge("size" => "1024x1024", "quality" => "medium", "n" => 1)
    end

    def media_reservation(path, payload)
      prepare_media(path, payload)
      if path == "/v1beta/interactions"
        # Reserve all 32768 maximum output tokens at the highest image rate,
        # even if the result contains cheaper text/thinking or fewer images.
        return {model: payload.fetch("model"), cost_microusd: ((JSON.generate(payload).bytesize + 4096) + 32768 * 120)}
      end
      prompt = payload["prompt"]
      raise EvalBudget::Rejected, "Eval image prompt required" unless prompt.is_a?(String) && prompt.bytesize <= 100_000
      image_tokens = 0
      if path == "/v1/images/edits"
        encoded = payload["eval_source_image"]
        raise EvalBudget::Rejected, "Bounded edit source required" unless encoded.is_a?(String) && encoded.bytesize <= 2_000_000
        bytes = Base64.strict_decode64(encoded)
        width, height = eval_image_dimensions(bytes)
        raise EvalBudget::Rejected, "Eval edit source exceeds bounded dimensions" unless width <= 1024 && height <= 1024
        # High-fidelity reference input: deliberately reserve a 36k token ceiling.
        image_tokens = 36_000
      end
      # Conservative reserves above standard Image2 rates: $10/M text+image
      # input and $0.12 output for fixed 1024-square/medium (standard ~$0.053).
      { model: "gpt-image-2", cost_microusd: ((prompt.bytesize + 4096 + image_tokens) * 10 + 120_000) * 2 }
    end

    def vision_input_tokens(payload, model)
      images = []
      visit = lambda do |node|
        case node
        when Hash
          raise EvalBudget::Rejected, "Unsupported eval media context" if (node.keys & %w[file_id file_data audio video]).any? || %w[input_file input_audio video].include?(node["type"])
          if %w[input_image image_url].include?(node["type"])
            url = node["image_url"]
            url = url["url"] if url.is_a?(Hash)
            images << url
          end
          node.each_value { |value| visit.call(value) }
        when Array then node.each { |value| visit.call(value) }
        end
      end
      visit.call(payload)
      raise EvalBudget::Rejected, "Unrecognized eval image input" if images.empty?
      images.sum do |url|
        match = url.is_a?(String) && /\Adata:image\/(?:png|webp|jpeg);base64,([A-Za-z0-9+\/=]+)\z/.match(url)
        raise EvalBudget::Rejected, "Eval vision requires bounded inline images" unless match && match[1].bytesize <= 2_000_000
        bytes = Base64.strict_decode64(match[1])
        width, height = eval_image_dimensions(bytes)
        patches = ((width + 31) / 32) * ((height + 31) / 32)
        raise EvalBudget::Rejected, "Eval vision image exceeds patch contract" if patches > 30_000
        if model == "gpt-5.1"
          70 + 16 * 140 # Above documented high/auto 2048-square tile ceiling.
        elsif %w[gpt-5.2 gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna gpt-5-mini].include?(model)
          (patches * 1.2).ceil + 1
        else
          raise EvalBudget::Rejected, "Unsupported eval vision model pricing"
        end
      rescue ArgumentError
        raise EvalBudget::Rejected, "Invalid eval inline image", cause: nil
      end
    end

    def eval_image_dimensions(bytes)
      raise EvalBudget::Rejected, "Invalid eval image bytes" unless bytes.is_a?(String) && bytes.bytesize >= 25 && bytes.bytesize <= 1_500_000
      dimensions = if bytes.start_with?("\x89PNG\r\n\x1a\n".b)
        bytes.byteslice(16, 8).unpack("N2")
      elsif bytes.start_with?("RIFF") && bytes.byteslice(8, 4) == "WEBP"
        case bytes.byteslice(12, 4)
        when "VP8X"
          [bytes.byteslice(24, 3), bytes.byteslice(27, 3)].map { |part| part && (part.unpack1("H*").scan(/../).reverse.join.to_i(16) + 1) }
        when "VP8L"
          bits = bytes.byteslice(21, 4).unpack1("V")
          [(bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1]
        when "VP8 "
          raise EvalBudget::Rejected, "Invalid eval WebP" unless bytes.byteslice(23, 3) == "\x9d\x01\x2a".b
          bytes.byteslice(26, 4).unpack("v2").map { |value| value & 0x3fff }
        end
      elsif bytes.start_with?("\xff\xd8".b)
        offset = 2
        found = nil
        while offset + 8 < bytes.bytesize
          break unless bytes.getbyte(offset) == 0xff
          marker = bytes.getbyte(offset + 1)
          length = bytes.byteslice(offset + 2, 2).unpack1("n")
          break if length < 2
          if [0xc0, 0xc1, 0xc2].include?(marker)
            h, w = bytes.byteslice(offset + 5, 4).unpack("n2")
            found = [w, h]
            break
          end
          offset += length + 2
        end
        found
      end
      raise EvalBudget::Rejected, "Unsupported eval image dimensions" unless dimensions&.all? { |value| value.is_a?(Integer) && value.positive? }
      dimensions
    rescue NoMethodError, TypeError
      raise EvalBudget::Rejected, "Invalid eval image header", cause: nil
    end
  end
end
