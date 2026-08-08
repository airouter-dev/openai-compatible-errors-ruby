# frozen_string_literal: true

require_relative "test_helper"

class RedactionTest < Minitest::Test
  def test_redacts_common_credentials
    result = OpenAICompatibleErrors.redact_sensitive_text(
      "Bearer abcdefghijklmnop sk-secret-token-123 api_key=also-secret"
    )

    assert_includes result, "[REDACTED]"
    assert_includes_no_secret(result, "abcdefghijklmnop")
    assert_includes_no_secret(result, "secret-token-123")
    assert_includes_no_secret(result, "also-secret")
  end

  def test_sanitizer_redacts_sensitive_keys_without_reading_exception_message
    error = RuntimeError.new("customer prompt should never become diagnostic context")
    value = {
      "api_key" => "key-to-hide",
      "nested" => { "authorization" => "Bearer key-to-hide", "ok" => "fine" },
      "exception" => error
    }

    sanitized = OpenAICompatibleErrors.sanitize_for_log(value)

    assert_equal "[REDACTED]", sanitized["api_key"]
    assert_equal "[REDACTED]", sanitized["nested"]["authorization"]
    assert_equal "fine", sanitized["nested"]["ok"]
    assert_equal "[RuntimeError]", sanitized["exception"]
    assert_includes_no_secret(sanitized, "customer prompt")
    assert_includes_no_secret(sanitized, "key-to-hide")
  end

  def test_sanitizer_breaks_cycles_and_bounds_collections
    looped = []
    looped << looped
    sanitized = OpenAICompatibleErrors.sanitize_for_log(
      { "items" => (1..40).to_a, "loop" => looped },
      limits: OpenAICompatibleErrors::Redaction::Limits.new(max_items: 3, max_keys: 3)
    )

    assert_equal [1, 2, 3, "[TRUNCATED]"], sanitized["items"]
    assert_equal ["[REDACTED]"], sanitized["loop"]
  end
end
