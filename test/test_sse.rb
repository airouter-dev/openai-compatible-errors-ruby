# frozen_string_literal: true

require_relative "test_helper"

class SSETest < Minitest::Test
  def test_inspects_chat_chunks_across_byte_boundaries
    inspector = OpenAICompatibleErrors::SSEInspector.new
    event = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
    event.bytes.each_slice(3) { |bytes| inspector.feed(bytes.pack("C*")) }
    inspector.feed("data: [DONE]\n\n")

    assert_equal :chat_completions, inspector.state.protocol
    assert inspector.state.has_output
    assert inspector.state.done?
    assert_equal 2, inspector.state.events_seen
  end

  def test_responses_metadata_does_not_claim_output_but_delta_does
    inspector = OpenAICompatibleErrors::SSEInspector.new
    inspector.feed("event: response.created\ndata: {\"type\":\"response.created\"}\n\n")
    refute inspector.state.has_output

    inspector.feed(
      "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}\n\n"
    )
    inspector.feed("event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n")

    assert_equal :responses, inspector.state.protocol
    assert inspector.state.has_output
    assert inspector.state.done?
  end

  def test_error_event_normalizes_without_provider_message_by_default
    inspector = OpenAICompatibleErrors::SSEInspector.new
    inspector.feed(
      "event: error\ndata: {\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"Bearer never-log\"}}\n\n"
    )

    assert_equal :error, inspector.state.termination
    assert_equal :sse, inspector.state.error.source
    assert_equal :rate_limit, inspector.state.error.category
    assert_nil inspector.state.error.provider_message
    assert_includes_no_secret(inspector.state.error.to_h, "never-log")
  end

  def test_malformed_utf8_and_oversized_events_become_stream_errors
    malformed = OpenAICompatibleErrors::SSEInspector.new
    malformed.feed("data: ".b + [0xFF].pack("C") + "\n\n".b)
    assert_equal :error, malformed.state.termination
    assert_equal 1, malformed.state.malformed_events

    oversized = OpenAICompatibleErrors::SSEInspector.new(max_event_bytes: 10)
    oversized.feed("data: {\"x\":\"too long\"}\n\n")
    assert_equal :error, oversized.state.termination
    assert_equal 1, oversized.state.malformed_events
  end

  def test_close_records_unexpected_eof_after_output
    inspector = OpenAICompatibleErrors::SSEInspector.new
    inspector.feed("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n")
    inspector.close

    assert inspector.state.has_output
    assert inspector.state.unexpected_eof?
    assert_equal :stream, inspector.state.error.category
  end

  def test_adapter_preserves_chunks_and_marks_source_failure
    inspector = OpenAICompatibleErrors::SSEInspector.new
    chunks = ["data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n", "data: [DONE]\n\n"]
    received = []

    state = OpenAICompatibleErrors::SSEInspector.inspect_each(chunks, inspector: inspector) do |chunk|
      received << chunk
    end

    assert_equal chunks, received
    assert state.done?
  end
end
