# frozen_string_literal: true

require "minitest/autorun"
require "openai_compatible_errors"

class Minitest::Test
  def assert_includes_no_secret(value, secret)
    refute_includes(value.to_s, secret)
  end
end
