# frozen_string_literal: true

require "time"

module OpenAICompatibleErrors
  module Headers
    MAX_RETRY_AFTER_MS = 86_400_000
    MAX_HEADER_VALUE_CHARS = 512
    REQUEST_ID_NAMES = %w[x-request-id request-id x-correlation-id trace-id].freeze
    RETRY_NAMES = %w[retry-after retry-after-ms x-retry-after-ms].freeze

    module_function

    def materialize(input)
      pairs = []
      if input.is_a?(Hash)
        input.each_pair { |key, value| pairs << [key, value] }
      elsif input.respond_to?(:each_header)
        begin
          input.each_header { |key, value| pairs << [key, value] }
        rescue StandardError
          pairs = []
        end
      elsif input.respond_to?(:each_pair)
        begin
          input.each_pair { |key, value| pairs << [key, value] }
        rescue StandardError
          pairs = []
        end
      end

      result = Hash.new { |hash, key| hash[key] = [] }
      pairs.each do |key, value|
        name = key.to_s.strip.downcase
        next unless name.match?(/\A[a-z0-9][a-z0-9_-]{0,127}\z/)

        values = value.is_a?(Array) ? value : [value]
        values.each do |item|
          text = item.is_a?(String) ? item : item.to_s
          next if text.empty? || text.bytesize > MAX_HEADER_VALUE_CHARS

          result[name] << text
        end
      end
      result
    end

    def values(input, name)
      materialize(input)[name.to_s.downcase]
    end

    def request_id(input)
      headers = materialize(input)
      REQUEST_ID_NAMES.each do |name|
        headers[name].each do |candidate|
          value = candidate.strip
          next unless value.match?(/\A[A-Za-z0-9][A-Za-z0-9._:\/-]{0,255}\z/)
          next if value.match?(/bearer|api[_ -]?key|secret|token/i)

          return value
        end
      end
      nil
    end

    # Returns a bounded delay. A malformed present hint returns the maximum
    # sentinel so a conservative retry policy fails closed.
    def retry_after_ms(input, now: Time.now)
      headers = materialize(input)
      candidates = []
      malformed = false
      RETRY_NAMES.each do |name|
        headers[name].each do |value|
          parsed =
            if name.end_with?("-ms")
              parse_milliseconds(value)
            else
              parse_retry_after(value, now: now)
            end
          if parsed.nil?
            malformed = true
          else
            candidates << parsed
          end
        end
      end
      return candidates.max unless candidates.empty?
      malformed ? MAX_RETRY_AFTER_MS : nil
    end

    def parse_milliseconds(value)
      return nil unless value.match?(/\A\d{1,12}\z/)

      [value.to_i, MAX_RETRY_AFTER_MS].min
    end

    def parse_retry_after(value, now:)
      if value.match?(/\A\d{1,8}\z/)
        return [value.to_i * 1_000, MAX_RETRY_AFTER_MS].min
      end
      return nil unless value.bytesize <= 128

      begin
        seconds = Time.httpdate(value).to_f - now.to_f
        return [[(seconds * 1_000).ceil, 0].max, MAX_RETRY_AFTER_MS].min
      rescue ArgumentError
        nil
      end
    end
  end
end
