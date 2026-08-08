# frozen_string_literal: true

require_relative "test_helper"

class RetryTest < Minitest::Test
  def error(category: :rate_limit, retry_after_ms: nil)
    OpenAICompatibleErrors::ApiError.new(
      category: category,
      source: :http,
      retry_after_ms: retry_after_ms
    )
  end

  def context(**overrides)
    OpenAICompatibleErrors::RetryContext.new(
      method: "POST",
      phase: :http_error,
      replay_safety: :safe,
      attempt: 1,
      elapsed_ms: 100,
      **overrides
    )
  end

  def test_uses_server_retry_after_when_evidence_is_safe
    plan = OpenAICompatibleErrors.decide_retry(error(retry_after_ms: 2_000), context)

    assert_equal :retry, plan.action
    assert_equal :transient_and_replay_safe, plan.reason
    assert_equal 2_000, plan.delay_ms
    assert_equal :server, plan.delay_source
  end

  def test_never_retries_after_partial_stream_output
    plan = OpenAICompatibleErrors.decide_retry(error, context(has_stream_output: true))

    assert_equal :do_not_retry, plan.action
    assert_equal :partial_stream_output, plan.reason
  end

  def test_treats_quota_as_permanent
    plan = OpenAICompatibleErrors.decide_retry(error(category: :quota), context)

    assert_equal :do_not_retry, plan.action
    assert_equal :permanent_error, plan.reason
  end

  def test_requires_known_phase_and_replay_safety
    phase_plan = OpenAICompatibleErrors.decide_retry(error, context(phase: :unknown))
    safety_plan = OpenAICompatibleErrors.decide_retry(
      error,
      context(replay_safety: :unknown)
    )

    assert_equal :manual_decision, phase_plan.action
    assert_equal :unknown_phase, phase_plan.reason
    assert_equal :manual_decision, safety_plan.action
    assert_equal :unknown_replay_safety, safety_plan.reason
  end

  def test_honors_attempt_and_time_budgets
    attempt_plan = OpenAICompatibleErrors.decide_retry(
      error,
      context(attempt: 3),
      policy: OpenAICompatibleErrors::RetryPolicy.new(max_attempts: 3)
    )
    time_plan = OpenAICompatibleErrors.decide_retry(
      error,
      context(elapsed_ms: 30_000)
    )

    assert_equal :attempt_budget_exhausted, attempt_plan.reason
    assert_equal :time_budget_exhausted, time_plan.reason
  end

  def test_invalid_random_source_fails_closed
    plan = OpenAICompatibleErrors.decide_retry(error, context, random: -> { 2 })

    assert_equal :manual_decision, plan.action
    assert_equal :invalid_context, plan.reason
  end

  def test_malformed_header_sentinel_does_not_fit_default_delay_budget
    plan = OpenAICompatibleErrors.decide_retry(
      error(retry_after_ms: OpenAICompatibleErrors::Headers::MAX_RETRY_AFTER_MS),
      context
    )

    assert_equal :do_not_retry, plan.action
    assert_equal :retry_after_exceeds_budget, plan.reason
  end
end
