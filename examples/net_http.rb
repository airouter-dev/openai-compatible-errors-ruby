# frozen_string_literal: true

require "logger"
require "openai_compatible_errors"

# This example uses a synthetic response so it never contacts a provider.
response = {
  status: 429,
  headers: {
    "retry-after" => "1",
    "x-request-id" => "req_example"
  },
  body: {
    error: {
      code: "rate_limit_exceeded",
      type: "requests",
      message: "provider-controlled detail"
    }
  }
}

error = OpenAICompatibleErrors.normalize_error(response)
Logger.new($stdout).warn(error.to_log_h)

context = OpenAICompatibleErrors::RetryContext.new(
  method: "POST",
  phase: :http_error,
  replay_safety: :safe,
  attempt: 1,
  elapsed_ms: 120
)
puts OpenAICompatibleErrors.decide_retry(error, context).to_h
