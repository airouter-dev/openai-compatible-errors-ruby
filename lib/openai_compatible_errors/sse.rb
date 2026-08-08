# frozen_string_literal: true

require "json"

module OpenAICompatibleErrors
  StreamState = Struct.new(:events_seen, :malformed_events, :has_output,
                           :protocol, :termination, :error, keyword_init: true) do
    def initialize(events_seen: 0, malformed_events: 0, has_output: false,
                   protocol: :unknown, termination: :open, error: nil)
      super
      freeze
    end

    def done?
      termination == :done
    end

    def incomplete?
      termination == :incomplete
    end

    def unexpected_eof?
      termination == :unexpected_eof
    end
  end

  class SSEInspector
    MAX_EVENT_BYTES = 65_536
    MAX_BUFFER_BYTES = 131_072
    RESPONSE_TERMINALS = %w[response.completed response.incomplete response.failed].freeze

    attr_reader :state

    def initialize(max_event_bytes: MAX_EVENT_BYTES, max_buffer_bytes: MAX_BUFFER_BYTES,
                   include_provider_message: false)
      @max_event_bytes = bounded_limit(max_event_bytes, MAX_EVENT_BYTES, 1, 1_048_576)
      @max_buffer_bytes = bounded_limit(max_buffer_bytes, MAX_BUFFER_BYTES, 1, 2_097_152)
      @include_provider_message = (include_provider_message == true)
      @buffer = +"".b
      @at_start = true
      @state = StreamState.new
    end

    def feed(chunk)
      return @state unless open?
      raise TypeError, "SSE chunks must be String instances" unless chunk.is_a?(String)

      @buffer << chunk.b
      return protocol_error! if @buffer.bytesize > @max_buffer_bytes

      loop do
        boundary = event_boundary(@buffer)
        break unless boundary

        raw, offset = boundary
        @buffer = @buffer.byteslice(offset, @buffer.bytesize - offset) || +"".b
        consume_event(raw)
        break unless open?
      end
      @state
    end

    def close
      return @state unless open?

      consume_event(@buffer) unless @buffer.empty?
      @buffer = +"".b
      finish(:unexpected_eof, stream_error) if open?
      @state
    end

    def fail
      finish(:error, stream_error) if open?
      @state
    end

    def self.inspect_each(enum, inspector: new)
      return enum_for(__method__, enum, inspector: inspector) unless block_given?

      begin
        enum.each do |chunk|
          inspector.feed(chunk)
          yield chunk
        end
        inspector.close
      rescue StandardError
        inspector.fail
        raise
      end
      inspector.state
    end

    private

    def open?
      @state.termination == :open
    end

    def bounded_limit(value, fallback, minimum, maximum)
      return fallback unless value.is_a?(Integer)

      [[value, minimum].max, maximum].min
    end

    def event_boundary(bytes)
      indexes = []
      index = bytes.index("\n\n".b)
      indexes << [index, 2] if index
      index = bytes.index("\r\r".b)
      indexes << [index, 2] if index
      index = bytes.index("\r\n\r\n".b)
      indexes << [index, 4] if index
      index = bytes.index("\n\r\n".b)
      indexes << [index, 3] if index
      return nil if indexes.empty?

      start, length = indexes.min_by(&:first)
      [bytes.byteslice(0, start), start + length]
    end

    def consume_event(raw)
      return if raw.empty?
      return protocol_error! if raw.bytesize > @max_event_bytes

      text =
        begin
          candidate = raw.dup.force_encoding(Encoding::UTF_8)
          raise EncodingError, "invalid UTF-8" unless candidate.valid_encoding?

          candidate
        rescue EncodingError, ArgumentError
          return protocol_error!
        end
      if @at_start && text.start_with?("\uFEFF")
        text = text.byteslice(3..)
      end
      @at_start = false

      event_name = nil
      data_lines = []
      text.split(/\r\n|\n|\r/, -1).each do |line|
        next if line.empty? || line.start_with?(":")

        field, value = line.split(":", 2)
        value = value.to_s.sub(/\A /, "")
        case field
        when "event"
          event_name = value.byteslice(0, 128)
        when "data"
          data_lines << value
        end
      end
      return if data_lines.empty?

      data = data_lines.join("\n")
      @state = with_state(events_seen: @state.events_seen + 1)
      return finish(:done, nil) if data == "[DONE]"

      payload =
        begin
          JSON.parse(data, allow_nan: false, max_nesting: 100)
        rescue JSON::ParserError, ArgumentError, SystemStackError
          return protocol_error!
        end
      update_protocol(payload, event_name)

      if error_event?(payload, event_name)
        return finish(:error, Normalizer.normalize(payload,
          source: :sse, include_provider_message: @include_provider_message))
      end
      return finish(:done, nil) if terminal_completed?(payload, event_name)
      return finish(:incomplete, nil) if terminal_incomplete?(payload, event_name)

      @state = with_state(has_output: true) if output_event?(payload, event_name)
      @state
    end

    def update_protocol(payload, event_name)
      type = hash_value(payload, "type")
      object = hash_value(payload, "object")
      protocol =
        if (type.is_a?(String) && type.start_with?("response.")) ||
           (event_name.is_a?(String) && event_name.start_with?("response."))
          :responses
        elsif hash_value(payload, "choices").is_a?(Array) ||
              (object.is_a?(String) && object.start_with?("chat.completion"))
          :chat_completions
        else
          :unknown
        end
      @state = with_state(protocol: protocol) unless protocol == :unknown
    end

    def error_event?(payload, event_name)
      return true if %w[error response.failed].include?(event_name.to_s.downcase)
      return true if hash_value(payload, "error")
      return true if hash_value(payload, "type").to_s == "error"

      response = hash_value(payload, "response")
      response.is_a?(Hash) &&
        (response["status"] == "failed" || !response["error"].nil?)
    end

    def terminal_completed?(payload, event_name)
      event_name == "response.completed" ||
        hash_value(payload, "type") == "response.completed"
    end

    def terminal_incomplete?(payload, event_name)
      event_name == "response.incomplete" ||
        hash_value(payload, "type") == "response.incomplete"
    end

    def output_event?(payload, event_name)
      signal = hash_value(payload, "type")
      signal = event_name unless signal.is_a?(String)
      if signal.is_a?(String) &&
         (signal.end_with?(".delta") || signal.end_with?("-delta") ||
          signal.start_with?("response.output_") ||
          signal.start_with?("response.content_part.") ||
          signal.start_with?("response.refusal.") ||
          signal.start_with?("response.reasoning_") ||
          signal == "response.image_generation_call.partial_image")
        return true
      end

      choices = hash_value(payload, "choices")
      if choices.is_a?(Array)
        choices.first(128).each do |choice|
          next unless choice.is_a?(Hash)

          delta = choice["delta"]
          if delta.is_a?(Hash) && %w[content refusal reasoning reasoning_content
                                     audio tool_calls function_call].any? do |key|
               value = delta[key]
               !value.nil? && value != "" && value != [] && value != {}
             end
            return true
          end
          return true if choice["message"] || choice["text"]
        end
      end
      delta = hash_value(payload, "delta")
      return true if delta.is_a?(String) && !delta.empty?

      response = hash_value(payload, "response")
      return true if response.is_a?(Hash) && response["output"] && response["output"] != []

      # Unknown data events are treated as potentially visible output. A false
      # positive blocks an unsafe replay; a false negative could duplicate it.
      !%w[response.created response.in_progress response.queued response.completed
          response.incomplete response.failed error].include?(signal.to_s)
    end

    def hash_value(value, key)
      value.is_a?(Hash) ? (value[key] || value[key.to_sym]) : nil
    end

    def with_state(**changes)
      values = {
        events_seen: @state.events_seen,
        malformed_events: @state.malformed_events,
        has_output: @state.has_output,
        protocol: @state.protocol,
        termination: @state.termination,
        error: @state.error
      }.merge(changes)
      StreamState.new(**values)
    end

    def stream_error
      ApiError.new(category: :stream, source: :sse)
    end

    def protocol_error!
      @state = with_state(malformed_events: @state.malformed_events + 1)
      finish(:error, stream_error)
    end

    def finish(termination, error)
      @state = with_state(termination: termination, error: error)
    end
  end
end
