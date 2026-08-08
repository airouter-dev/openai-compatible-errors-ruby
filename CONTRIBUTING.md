# Contributing

## Local validation

This gem intentionally has no runtime dependencies. With Ruby 3.0 or newer:

    bundle install
    bundle exec rake test
    gem build openai-compatible-errors.gemspec

The tests never call an API, open a network connection, sleep, or use real
credentials. Keep fixtures synthetic and bounded.

## Design boundaries

- normalize_error returns a snapshot; it does not raise a provider exception
  again or retain a raw body.
- decide_retry returns a plan; the caller owns waiting, cancellation,
  idempotency and replay.
- SSEInspector retains replay-boundary state only, never generated text.
- Redaction reduces logging risk but is not a substitute for a data-retention
  policy.

Please add a regression test for every new provider shape and document whether
the shape is observed in HTTP headers, a structured body, an SDK exception, or
an SSE event.
