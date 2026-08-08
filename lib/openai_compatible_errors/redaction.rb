# frozen_string_literal: true

module OpenAICompatibleErrors
  module Redaction
    SENSITIVE_KEY = /(authorization|api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|secret|password|cookie|prompt|completion)/i
    REDACTED = "[REDACTED]".freeze
    TRUNCATED = "[TRUNCATED]".freeze

    Limits = Struct.new(:max_depth, :max_nodes, :max_keys, :max_items,
                        :max_chars, :max_replacements, keyword_init: true) do
      def initialize(max_depth: 4, max_nodes: 250, max_keys: 32, max_items: 32,
                     max_chars: 8_192, max_replacements: 64)
        super
        raise ArgumentError, "limits must be positive" unless [max_depth, max_nodes,
          max_keys, max_items, max_chars, max_replacements].all? do |value|
          value.is_a?(Integer) && value.positive?
        end
        freeze
      end
    end

    module_function

    def redact_sensitive_text(value, max_chars: 2_000)
      return nil unless value.is_a?(String)

      text = value.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
      replacements = 0
      patterns = [
        [/\bBearer\s+[A-Za-z0-9._~+\/=-]+/i, "Bearer #{REDACTED}"],
        [/\b(?:sk(?:-proj|-ant)?|xai|ghp|github_pat|hf|r8)[_-][A-Za-z0-9_-]{8,}/, REDACTED],
        [/(api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|authorization)\s*[:=]\s*[^\s,;]+/i,
         "\\1=#{REDACTED}"]
      ]
      patterns.each do |pattern, replacement|
        text = text.gsub(pattern) do
          replacements += 1
          if replacement.include?("\\1")
            "#{Regexp.last_match(1)}=#{REDACTED}"
          else
            replacement
          end
        end
      end
      text = text.byteslice(0, max_chars).to_s.scrub
      replacements.positive? ? text : text
    rescue EncodingError
      REDACTED
    end

    def sanitize_for_log(value, limits: Limits.new)
      state = { nodes: 0, chars: 0, replacements: 0, seen: {} }
      sanitize_value(value, depth: 0, limits: limits, state: state)
    end

    def sensitive_key?(key)
      key.is_a?(String) || key.is_a?(Symbol) ? key.to_s.match?(SENSITIVE_KEY) : false
    end

    def sanitize_value(value, depth:, limits:, state:)
      state[:nodes] += 1
      return REDACTED if state[:nodes] > limits.max_nodes
      return REDACTED if depth > limits.max_depth

      case value
      when nil, true, false, Numeric
        value
      when Symbol
        value.to_s
      when String
        sanitize_string(value, limits, state)
      when Exception
        "[#{value.class.name || "Exception"}]"
      when Hash
        return REDACTED if state[:seen][value.object_id]

        state[:seen][value.object_id] = true
        result = {}
        value.first(limits.max_keys).each do |key, item|
          normalized_key = key.is_a?(String) || key.is_a?(Symbol) ? key.to_s : "[KEY]"
          result[normalized_key] = if sensitive_key?(normalized_key)
                                     state[:replacements] += 1
                                     REDACTED
                                   else
                                     sanitize_value(item, depth: depth + 1,
                                                    limits: limits, state: state)
                                   end
        end
        result["[TRUNCATED]"] = TRUNCATED if value.size > limits.max_keys
        result
      when Array
        return REDACTED if state[:seen][value.object_id]

        state[:seen][value.object_id] = true
        result = value.first(limits.max_items).map do |item|
          sanitize_value(item, depth: depth + 1, limits: limits, state: state)
        end
        result << TRUNCATED if value.size > limits.max_items
        result
      else
        "[#{value.class.name || "Object"}]"
      end
    end

    def sanitize_string(value, limits, state)
      text = redact_sensitive_text(value, max_chars: limits.max_chars)
      state[:chars] += text.to_s.length
      if state[:chars] > limits.max_chars
        state[:replacements] += 1
        return REDACTED
      end
      text
    end
  end
end
