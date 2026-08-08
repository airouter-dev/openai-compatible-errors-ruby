# frozen_string_literal: true

module OpenAICompatibleErrors
  RETRY_ACTIONS = %i[retry do_not_retry manual_decision].freeze
  RETRY_REASONS = %i[
    transient_and_replay_safe
    partial_stream_output
    request_completed
    conflict_requires_resolution
    replay_unsafe
    caller_aborted
    permanent_error
    attempt_budget_exhausted
    time_budget_exhausted
    retry_after_exceeds_budget
    unclassified_error
    unknown_phase
    unknown_replay_safety
    invalid_context
  ].freeze
  REQUEST_PHASES = %i[
    before_send awaiting_headers http_error sse_before_output
    sse_after_output completed unknown
  ].freeze
  REPLAY_SAFETY = %i[safe unsafe unknown].freeze
  DELAY_SOURCES = %i[server backoff].freeze

  class RetryContext
    attr_reader :method, :phase, :replay_safety, :attempt, :elapsed_ms,
                :has_stream_output

    def initialize(method:, phase:, replay_safety:, attempt:, elapsed_ms:,
                   has_stream_output: false)
      @method = method.is_a?(String) ? method.strip.upcase : ""
      @phase = coerce(phase, REQUEST_PHASES, :unknown)
      @replay_safety = coerce(replay_safety, REPLAY_SAFETY, :unknown)
      @attempt = attempt.is_a?(Integer) && attempt.positive? ? attempt : 0
      @elapsed_ms = elapsed_ms.is_a?(Integer) && elapsed_ms >= 0 ? elapsed_ms : -1
      @has_stream_output = (has_stream_output == true)
      freeze
    end

    private

    def coerce(value, allowed, fallback)
      candidate = value.is_a?(Symbol) ? value : value.to_s.strip.downcase.to_sym
      allowed.include?(candidate) ? candidate : fallback
    end
  end

  class RetryPolicy
    attr_reader :max_attempts, :max_elapsed_ms, :base_delay_ms,
                :max_delay_ms, :jitter

    def initialize(max_attempts: 3, max_elapsed_ms: 30_000, base_delay_ms: 500,
                   max_delay_ms: 10_000, jitter: :full)
      @max_attempts = positive_integer(max_attempts)
      @max_elapsed_ms = positive_integer(max_elapsed_ms)
      @base_delay_ms = non_negative_integer(base_delay_ms)
      @max_delay_ms = positive_integer(max_delay_ms)
      jitter_symbol = jitter.is_a?(Symbol) || jitter.is_a?(String) ? jitter.to_sym : :full
      @jitter = %i[full none].include?(jitter_symbol) ? jitter_symbol : :full
      raise ArgumentError, "max_delay_ms must be at least base_delay_ms" if @max_delay_ms < @base_delay_ms

      freeze
    end

    private

    def positive_integer(value)
      raise ArgumentError, "expected a positive integer" unless value.is_a?(Integer) && value.positive?

      value
    end

    def non_negative_integer(value)
      raise ArgumentError, "expected a non-negative integer" unless value.is_a?(Integer) && value >= 0

      value
    end
  end

  class RetryPlan
    attr_reader :action, :reason, :delay_ms, :delay_source

    def initialize(action:, reason:, delay_ms: nil, delay_source: nil)
      action_symbol = action.is_a?(Symbol) || action.is_a?(String) ? action.to_sym : nil
      reason_symbol = reason.is_a?(Symbol) || reason.is_a?(String) ? reason.to_sym : nil
      @action = RETRY_ACTIONS.include?(action_symbol) ? action_symbol : :manual_decision
      @reason = RETRY_REASONS.include?(reason_symbol) ? reason_symbol : :invalid_context
      @delay_ms = delay_ms.is_a?(Integer) && delay_ms >= 0 ? delay_ms : nil
      source_symbol = delay_source.is_a?(Symbol) || delay_source.is_a?(String) ? delay_source.to_sym : nil
      @delay_source = DELAY_SOURCES.include?(source_symbol) ? source_symbol : nil
      freeze
    end

    def retry?
      @action == :retry
    end

    def do_not_retry?
      @action == :do_not_retry
    end

    def manual_decision?
      @action == :manual_decision
    end

    def to_h
      { action: @action, reason: @reason, delay_ms: @delay_ms,
        delay_source: @delay_source }.compact.freeze
    end
  end

  module Retry
    TRANSIENT = %i[rate_limit timeout network upstream server stream].freeze
    PERMANENT = %i[authentication permission quota validation not_found
                   payload_too_large endpoint].freeze

    module_function

    def decide_retry(error, context, policy: RetryPolicy.new, random: nil)
      return plan(:manual_decision, :invalid_context) unless error.is_a?(ApiError)
      return plan(:manual_decision, :invalid_context) unless context.is_a?(RetryContext)
      return plan(:manual_decision, :invalid_context) unless policy.is_a?(RetryPolicy)
      return plan(:manual_decision, :invalid_context) unless context.attempt.positive? &&
        context.elapsed_ms >= 0 && !context.method.empty?

      return plan(:do_not_retry, :partial_stream_output) if context.has_stream_output ||
        context.phase == :sse_after_output
      return plan(:do_not_retry, :request_completed) if context.phase == :completed
      return plan(:do_not_retry, :caller_aborted) if error.category == :aborted
      return plan(:manual_decision, :conflict_requires_resolution) if error.category == :conflict
      return plan(:do_not_retry, :permanent_error) if PERMANENT.include?(error.category)
      return plan(:do_not_retry, :replay_unsafe) if context.replay_safety == :unsafe
      return plan(:manual_decision, :unknown_phase) if context.phase == :unknown
      return plan(:manual_decision, :unknown_replay_safety) if context.replay_safety == :unknown
      return plan(:manual_decision, :unclassified_error) unless TRANSIENT.include?(error.category)
      return plan(:do_not_retry, :attempt_budget_exhausted) if context.attempt >= policy.max_attempts
      return plan(:do_not_retry, :time_budget_exhausted) if context.elapsed_ms >= policy.max_elapsed_ms

      if error.retry_after_ms
        delay = error.retry_after_ms
        return plan(:do_not_retry, :retry_after_exceeds_budget) if delay > policy.max_delay_ms ||
          context.elapsed_ms + delay > policy.max_elapsed_ms

        return RetryPlan.new(action: :retry, reason: :transient_and_replay_safe,
                             delay_ms: delay, delay_source: :server)
      end

      exponent = [context.attempt - 1, 30].min
      cap = [policy.base_delay_ms * (2**exponent), policy.max_delay_ms].min
      delay =
        if policy.jitter == :none
          cap
        else
          sample = random ? random.call : Kernel.rand
          return plan(:manual_decision, :invalid_context) unless sample.is_a?(Numeric) &&
            sample.finite? && sample >= 0 && sample <= 1

          (cap * sample).round
        end
      return plan(:do_not_retry, :time_budget_exhausted) if context.elapsed_ms + delay > policy.max_elapsed_ms

      RetryPlan.new(action: :retry, reason: :transient_and_replay_safe,
                    delay_ms: delay, delay_source: :backoff)
    rescue StandardError
      plan(:manual_decision, :invalid_context)
    end

    def plan(action, reason)
      RetryPlan.new(action: action, reason: reason)
    end
    private_class_method :plan
  end

  module_function

  def decide_retry(error, context, **options)
    Retry.decide_retry(error, context, **options)
  end
end
