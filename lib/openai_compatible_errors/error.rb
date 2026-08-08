# frozen_string_literal: true

module OpenAICompatibleErrors
  CATEGORIES = %i[
    authentication
    permission
    rate_limit
    quota
    conflict
    validation
    not_found
    payload_too_large
    timeout
    network
    upstream
    server
    schema
    endpoint
    aborted
    stream
    unknown
  ].freeze

  SOURCES = %i[http httpx openai_sdk sse unknown].freeze

  SAFE_MESSAGES = {
    authentication: "The API request could not be authenticated.",
    permission: "The API request was not permitted.",
    rate_limit: "The API rate limit was reached.",
    quota: "The API quota is unavailable or exhausted.",
    conflict: "The API request conflicted with current server state.",
    validation: "The API request was rejected as invalid.",
    not_found: "The requested API resource was not found.",
    payload_too_large: "The API request payload was too large.",
    timeout: "The API request timed out.",
    network: "The API request failed at the network boundary.",
    upstream: "The upstream API was temporarily unavailable.",
    server: "The API returned a server error.",
    schema: "The API payload did not match the expected schema.",
    endpoint: "The API endpoint was not found.",
    aborted: "The API request was cancelled by the caller.",
    stream: "The API stream ended with an error.",
    unknown: "The API request failed for an unclassified reason."
  }.freeze

  # A deliberately small immutable snapshot. Raw bodies, headers, causes and
  # tracebacks are not retained, so logging this object is safe by default.
  class ApiError
    attr_reader :category, :source, :status, :code, :type, :request_id,
                :retry_after_ms, :provider_message

    def initialize(category:, source:, status: nil, code: nil, type: nil,
                   request_id: nil, retry_after_ms: nil, provider_message: nil)
      @category = normalize_symbol(category, CATEGORIES, :unknown)
      @source = normalize_symbol(source, SOURCES, :unknown)
      @status = normalize_status(status)
      @code = bounded_text(code, 256)
      @type = bounded_text(type, 256)
      @request_id = bounded_text(request_id, 256)
      @retry_after_ms = normalize_delay(retry_after_ms)
      @provider_message = bounded_text(provider_message, 2_000)
      freeze
    end

    def message
      SAFE_MESSAGES.fetch(@category)
    end

    def to_h(include_provider_message: false)
      result = {
        message: message,
        category: @category,
        source: @source
      }
      { status: @status, code: @code, type: @type, request_id: @request_id,
        retry_after_ms: @retry_after_ms }.each do |key, value|
        result[key] = value unless value.nil?
      end
      if include_provider_message && !@provider_message.nil?
        result[:provider_message] = @provider_message
      end
      result.freeze
    end

    alias to_log_h to_h

    def retryable_category?
      %i[rate_limit timeout network upstream server stream].include?(@category)
    end

    def ==(other)
      other.is_a?(ApiError) &&
        [@category, @source, @status, @code, @type, @request_id,
         @retry_after_ms, @provider_message] ==
          [other.category, other.source, other.status, other.code, other.type,
           other.request_id, other.retry_after_ms, other.provider_message]
    end

    alias eql? ==

    def hash
      [@category, @source, @status, @code, @type, @request_id,
       @retry_after_ms, @provider_message].hash
    end

    def inspect
      "#<#{self.class} category=#{@category.inspect} source=#{@source.inspect} " \
        "status=#{@status.inspect} code=#{@code.inspect} type=#{@type.inspect} " \
        "request_id=#{@request_id.inspect} retry_after_ms=#{@retry_after_ms.inspect}>"
    end

    def to_s
      message
    end

    private

    def normalize_symbol(value, allowed, fallback)
      candidate =
        if value.is_a?(Symbol)
          value
        elsif value.is_a?(String) && value.bytesize <= 64
          value.strip.downcase.to_sym
        end
      allowed.include?(candidate) ? candidate : fallback
    end

    def normalize_status(value)
      candidate =
        if value.is_a?(Integer) && !value.is_a?(TrueClass) && !value.is_a?(FalseClass)
          value
        elsif value.is_a?(String) && value.bytesize <= 16 && value.strip.match?(/\A\d+\z/)
          value.to_i
        end
      candidate && candidate.between?(100, 599) ? candidate : nil
    end

    def normalize_delay(value)
      return nil unless value.is_a?(Integer) && !value.is_a?(TrueClass) &&
                        !value.is_a?(FalseClass) && value >= 0

      [value, Headers::MAX_RETRY_AFTER_MS].min
    rescue NameError
      [value, 86_400_000].min
    end

    def bounded_text(value, limit)
      return nil unless value.is_a?(String)

      value = value.strip
      return nil if value.empty?

      result = value.bytesize > limit ? value.byteslice(0, limit).scrub : value
      result.dup.freeze
    end
  end

  NormalizedError = ApiError
end
