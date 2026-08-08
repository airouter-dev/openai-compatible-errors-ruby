# frozen_string_literal: true

require "json"

module OpenAICompatibleErrors
  module Normalizer
    MAX_BODY_BYTES = 65_536
    MAX_IDENTIFIER_BYTES = 256
    UNSET = Object.new.freeze

    module_function

    def normalize(input, status: nil, headers: nil, body: nil,
                  include_provider_message: false, now: Time.now, source: nil)
      response_status, response_headers, response_body = response_parts(input)
      status = valid_status(status) || response_status
      headers = response_headers if headers.nil?
      body = response_body if body.nil?

      decoded = decode_body(body.nil? && input.is_a?(Hash) ? input : body)
      payload = error_payload(decoded)
      code = safe_identifier(first_value(:code, payload, decoded, input))
      error_type = safe_identifier(first_value(:type, payload, decoded, input))
      request_id = Headers.request_id(headers) ||
                   safe_identifier(first_value(:request_id, payload, decoded, input))
      class_name = safe_class_name(input)
      exception_message = exception_message(input)
      category = classify(status: status, code: code, error_type: error_type,
                          class_name: class_name, exception_message: exception_message)
      provider_message =
        if include_provider_message
          Redaction.redact_sensitive_text(
            first_text(payload, decoded, input),
            max_chars: 2_000
          )
        end

      ApiError.new(
        category: category,
        source: source || detect_source(input, status),
        status: status,
        code: code,
        type: error_type,
        request_id: request_id,
        retry_after_ms: Headers.retry_after_ms(headers, now: now),
        provider_message: provider_message
      )
    end

    def response_parts(input)
      status = valid_status(read(input, :status_code)) || valid_status(read(input, :status))
      headers = read(input, :headers)
      content = first_present(read(input, :body), read(input, :content), read(input, :data))

      nested_response = read(input, :response)
      if nested_response && nested_response != input
        status ||= valid_status(read(nested_response, :status_code)) ||
                   valid_status(read(nested_response, :status))
        headers ||= read(nested_response, :headers)
        content = first_present(content, read(nested_response, :body),
                                 read(nested_response, :content),
                                 read(nested_response, :data))
      end

      [status, headers, content]
    end

    def read(value, *keys)
      return UNSET if value.nil?

      if value.is_a?(Hash)
        keys.each do |key|
          return value[key] if value.key?(key)
          string_key = key.to_s
          return value[string_key] if value.key?(string_key)
        end
        return UNSET
      end

      keys.each do |key|
        next unless value.respond_to?(key)

        begin
          result = value.public_send(key)
          return result unless result.nil?
        rescue StandardError
          next
        end
      end
      UNSET
    end

    def first_present(*values)
      values.find { |value| value != UNSET && !value.nil? }
    end

    def valid_status(value)
      candidate =
        if value.is_a?(Integer) && !value.is_a?(TrueClass) && !value.is_a?(FalseClass)
          value
        elsif value.is_a?(String) && value.bytesize <= 16 && value.strip.match?(/\A\d+\z/)
          value.to_i
        end
      candidate && candidate.between?(100, 599) ? candidate : nil
    end

    def decode_body(value)
      return nil if value == UNSET || value.nil?
      return value if value.is_a?(Hash) || value.is_a?(Array)

      if value.is_a?(String)
        return nil if value.bytesize > MAX_BODY_BYTES

        text = value.scrub
        candidate = text.strip
        return value unless candidate.start_with?("{", "[")

        begin
          return JSON.parse(candidate, allow_nan: false, max_nesting: 100)
        rescue JSON::ParserError, ArgumentError, SystemStackError
          return value
        end
      end

      if value.respond_to?(:to_hash)
        begin
          converted = value.to_hash
          return converted if converted.is_a?(Hash)
        rescue StandardError
          return value
        end
      end
      value
    end

    def error_payload(value)
      return value unless value.is_a?(Hash)

      nested = value[:response] || value["response"]
      if nested.is_a?(Hash)
        nested_error = nested[:error] || nested["error"]
        return nested_error unless nested_error.nil?
      end
      error = value[:error] || value["error"]
      error.nil? ? value : error
    end

    def first_value(field, *values)
      values.each do |value|
        next unless value.is_a?(Hash)

        return value[field] if value.key?(field) && !value[field].nil?
        string_key = field.to_s
        return value[string_key] if value.key?(string_key) && !value[string_key].nil?
      end
      UNSET
    end

    def first_text(*values)
      values.each do |value|
        next unless value.is_a?(Hash)

        candidate = value[:message] || value["message"]
        return candidate if candidate.is_a?(String) && !candidate.empty?
      end
      values.each do |value|
        candidate = exception_message(value)
        return candidate unless candidate.nil?
      end
      nil
    end

    def safe_identifier(value)
      return nil unless value.is_a?(String)

      candidate = value.strip
      return nil if candidate.empty? || candidate.bytesize > MAX_IDENTIFIER_BYTES
      return nil unless candidate.match?(/\A[A-Za-z0-9][A-Za-z0-9._:\/-]*\z/)
      return nil if candidate.match?(/bearer|api[_ -]?key|secret|token/i)

      candidate
    end

    def exception_message(value)
      return nil unless value.is_a?(Exception)

      begin
        text = value.message
        text.is_a?(String) && text.bytesize <= 2_000 ? text : nil
      rescue StandardError
        nil
      end
    end

    def safe_class_name(value)
      name = value.class.name
      name.is_a?(String) ? name.byteslice(0, 256).to_s : ""
    rescue StandardError
      ""
    end

    def detect_source(input, status)
      name = safe_class_name(input)
      return :openai_sdk if name.match?(/OpenAI|APIError|RateLimitError|AuthenticationError/i)
      return :httpx if name.start_with?("HTTPX::")
      return :http if status

      :unknown
    end

    def classify(status:, code:, error_type:, class_name:, exception_message:)
      structured = [code, error_type, class_name].compact.join(" ").downcase
      transport = [structured, exception_message].compact.join(" ").downcase

      return :schema if structured.include?("apiresponsevalidationerror")
      return :validation if [400, 422].include?(status)
      return :conflict if status == 409
      return :authentication if status == 401
      return :permission if status == 403
      if status == 404
        return structured.match?(/model|deployment|resource/) ? :not_found : :endpoint
      end
      return :timeout if status == 408
      return :payload_too_large if status == 413
      if status == 429
        return structured.match?(/insufficient[_ -]?quota|quota[_ -]?(exhausted|exceeded)|billing|credit/) ? :quota : :rate_limit
      end
      return :upstream if [502, 503, 504].include?(status)
      return :server if status && status >= 500
      return :validation if status && status >= 400

      return :timeout if structured.match?(/timeout|timedout|etimedout/)
      return :network if structured.match?(/connection|connecterror|proxyerror|protocolerror/)
      return :aborted if transport.match?(/abort|cancel/)
      return :quota if structured.match?(/insufficient[_ -]?quota|quota[_ -]?(exhausted|exceeded)|billing|credit/)
      return :authentication if structured.match?(/invalid[_ -]?api[_ -]?key|authentication|unauthori[sz]ed/)
      return :permission if structured.match?(/permission|forbidden|access[_ -]?denied/)
      return :rate_limit if structured.match?(/rate[_ -]?limit/)
      return :timeout if transport.match?(/timed?[_ -]?out|timeout|etimedout/)
      return :network if transport.match?(/connection|econnreset|econnrefused|enotfound|network/)
      return :schema if structured.match?(/json|schema|parse[_ -]?error|malformed|decode/)

      :unknown
    end
  end

  module_function

  def normalize_error(input = nil, **options)
    Normalizer.normalize(input, **options)
  end

  alias normalize normalize_error
end
