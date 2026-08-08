# frozen_string_literal: true

require_relative "openai_compatible_errors/version"
require_relative "openai_compatible_errors/error"
require_relative "openai_compatible_errors/headers"
require_relative "openai_compatible_errors/redaction"
require_relative "openai_compatible_errors/normalize"
require_relative "openai_compatible_errors/retry"
require_relative "openai_compatible_errors/sse"

module OpenAICompatibleErrors
  module_function

  def redact_sensitive_text(value, **options)
    Redaction.redact_sensitive_text(value, **options)
  end

  def sanitize_for_log(value, **options)
    Redaction.sanitize_for_log(value, **options)
  end
end
