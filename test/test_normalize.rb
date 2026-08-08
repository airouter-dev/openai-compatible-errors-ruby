# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class NormalizeTest < Minitest::Test
  FakeResponse = Struct.new(:status, :headers, :body, keyword_init: true)

  def test_normalizes_http_rate_limit_without_retaining_provider_message
    error = OpenAICompatibleErrors.normalize_error(
      status: 429,
      headers: { "Retry-After" => "2", "X-Request-Id" => "req_01" },
      body: {
        error: {
          code: "rate_limit_exceeded",
          type: "requests",
          message: "Bearer very-secret-token"
        }
      }
    )

    assert_equal :rate_limit, error.category
    assert_equal :http, error.source
    assert_equal 429, error.status
    assert_equal "rate_limit_exceeded", error.code
    assert_equal "requests", error.type
    assert_equal "req_01", error.request_id
    assert_equal 2_000, error.retry_after_ms
    assert_nil error.provider_message
    assert_equal "The API rate limit was reached.", error.message
    assert_includes_no_secret(error.to_h, "very-secret-token")
  end

  def test_provider_message_requires_explicit_opt_in_and_is_redacted
    error = OpenAICompatibleErrors.normalize_error(
      {
        status: 401,
        body: {
          error: { message: "authorization=never-log-this Bearer also-never-log" }
        }
      },
      include_provider_message: true
    )

    assert_equal :authentication, error.category
    assert_includes error.provider_message, "[REDACTED]"
    assert_includes_no_secret(error.provider_message, "never-log-this")
    assert_includes_no_secret(error.provider_message, "also-never-log")
    assert_nil error.to_h[:provider_message]
    assert_includes error.to_h(include_provider_message: true), :provider_message
  end

  def test_response_shape_and_http_date_retry_after_are_supported
    now = Time.utc(2026, 8, 9, 0, 0, 0)
    response = FakeResponse.new(
      status: "503",
      headers: { "retry-after" => (now + 5).httpdate, "x-request-id" => "req_503" },
      body: '{"error":{"code":"server_error","type":"internal"}}'
    )

    error = OpenAICompatibleErrors.normalize_error(response, now: now)

    assert_equal :upstream, error.category
    assert_equal :http, error.source
    assert_equal 5_000, error.retry_after_ms
    assert_equal "req_503", error.request_id
    assert_equal "server_error", error.code
    assert_equal "internal", error.type
  end

  def test_status_and_structured_code_precede_exception_text
    error = OpenAICompatibleErrors.normalize_error(
      Timeout::Error.new("connection reset"),
      status: 400,
      body: { error: { code: "invalid_request_error" } }
    )

    assert_equal :validation, error.category
  end

  def test_timeout_exception_is_classified_without_logging_message
    error = OpenAICompatibleErrors.normalize_error(Timeout::Error.new("secret prompt"))

    assert_equal :timeout, error.category
    assert_nil error.provider_message
    assert_includes_no_secret(error.to_h, "secret prompt")
  end

  def test_malformed_retry_hint_saturates_to_conservative_sentinel
    error = OpenAICompatibleErrors.normalize_error(
      status: 429,
      headers: { "retry-after" => "soon" }
    )

    assert_equal OpenAICompatibleErrors::Headers::MAX_RETRY_AFTER_MS, error.retry_after_ms
  end

  def test_invalid_identifiers_and_unbounded_body_are_dropped
    error = OpenAICompatibleErrors.normalize_error(
      status: 500,
      headers: { "x-request-id" => "Bearer should-not-pass" },
      body: "{\"error\":{\"code\":\"x\"}}" + (" " * 70_000)
    )

    assert_equal :server, error.category
    assert_nil error.request_id
    assert_nil error.code
  end

  def test_api_error_is_immutable_and_hides_provider_message_from_inspect
    error = OpenAICompatibleErrors::ApiError.new(
      category: :network,
      source: :unknown,
      provider_message: "do-not-print"
    )

    assert_predicate error, :frozen?
    refute_includes error.inspect, "do-not-print"
  end
end
