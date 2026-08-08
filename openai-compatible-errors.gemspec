# frozen_string_literal: true

require_relative "lib/openai_compatible_errors/version"

Gem::Specification.new do |spec|
  spec.name = "openai-compatible-errors"
  spec.version = OpenAICompatibleErrors::VERSION
  spec.authors = ["AI ROUTER contributors"]
  spec.summary = "Safe error normalization and replay boundaries for OpenAI-compatible APIs"
  spec.description = <<~DESCRIPTION
    A zero-runtime-dependency Ruby library that normalizes OpenAI-compatible HTTP
    and SDK failures, parses Retry-After hints, plans conservative retries, and
    inspects Chat Completions or Responses SSE streams without retaining raw
    provider payloads.
  DESCRIPTION
  spec.homepage = "https://ai-router.dev/"
  spec.required_ruby_version = ">= 3.0"
  spec.license = "MIT"
  spec.require_paths = ["lib"]

  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/airouter-dev/openai-compatible-errors-ruby/issues",
    "changelog_uri" => "https://github.com/airouter-dev/openai-compatible-errors-ruby/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://github.com/airouter-dev/openai-compatible-errors-ruby#readme",
    "homepage_uri" => "https://ai-router.dev/",
    "source_code_uri" => "https://github.com/airouter-dev/openai-compatible-errors-ruby",
    "rubygems_mfa_required" => "true"
  }

  included = %w[
    CHANGELOG.md
    CONTRIBUTING.md
    LICENSE
    README.md
    RELEASING.md
    SECURITY.md
    Gemfile
    Rakefile
  ]
  spec.files = included + Dir.glob("lib/**/*.rb") + Dir.glob("examples/**/*.rb")
  spec.files = spec.files.select { |path| File.file?(path) }.uniq.sort
  spec.test_files = Dir.glob("test/**/*.rb")
  spec.add_development_dependency "minitest", "~> 5.26.1"
  spec.add_development_dependency "rake", "~> 13.0"
end
