# Changelog

All notable changes to this gem are documented here.

## [0.1.2] - 2026-08-09

Metadata release.

- Point the RubyGems Homepage metadata to the AI-ROUTER gateway landing page.
- Keep source, documentation, changelog and issue links on the project repository.

## [0.1.1] - 2026-08-09

Documentation release.

- Add contextual links to the API gateway, protocol references, replay-safety
  research, and the maintained packages in other language ecosystems.
- Keep the Ruby implementation and its zero-runtime-dependency contract
  unchanged.

## [0.1.0] - 2026-08-09

Initial public release.

- Normalize HTTP-like hashes, response objects and common SDK exception shapes.
- Classify authentication, permission, rate-limit, quota, validation, conflict,
  transport, upstream, server, schema and stream failures.
- Parse bounded Retry-After and millisecond retry hints.
- Return immutable, safe-by-default error snapshots with optional redacted
  provider text.
- Plan retries only when the caller supplies replay-safety and stream-phase
  evidence.
- Inspect Chat Completions and Responses Server-Sent Events incrementally
  without retaining generated output.
- Provide bounded recursive log sanitization with cycle detection.

[0.1.1]: https://github.com/airouter-dev/openai-compatible-errors-ruby/releases/tag/v0.1.1
[0.1.2]: https://github.com/airouter-dev/openai-compatible-errors-ruby/releases/tag/v0.1.2
[0.1.0]: https://github.com/airouter-dev/openai-compatible-errors-ruby/releases/tag/v0.1.0
