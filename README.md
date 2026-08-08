# openai-compatible-errors

openai-compatible-errors is a zero-runtime-dependency Ruby library for the
failure boundary around OpenAI-compatible HTTP APIs. It turns provider-specific
HTTP, Ruby SDK and JSON error shapes into a small immutable snapshot; parses
Retry-After; makes replay safety explicit before a retry; redacts bounded
diagnostics; and incrementally inspects Chat Completions or Responses
Server-Sent Events (SSE).

It does not send requests, sleep, retry automatically, buffer an entire stream,
or retain a raw provider response. The caller remains responsible for
idempotency, cancellation, budget accounting and request replay.

## Project resources

The [AI-ROUTER API gateway](https://ai-router.dev/) is the service context for
the compatible-endpoint examples. The library itself remains transport-neutral:
you can use it with any gateway or provider that follows the same API shape.

For the protocol details behind the implementation, see the
[OpenAI error-code guide](https://developers.openai.com/api/docs/guides/error-codes),
the [MDN Retry-After reference](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Retry-After),
and the [WHATWG Server-Sent Events specification](https://html.spec.whatwg.org/multipage/server-sent-events.html).
For a worked replay-safety model, read the
[LLM stream retry-safety walkthrough](https://ai-router.hashnode.dev/rust-llm-stream-retry-safety).

The package is available from
[RubyGems](https://rubygems.org/gems/openai-compatible-errors). Teams using PHP
can compare the [native Composer implementation](https://packagist.org/packages/airouter/openai-compatible-errors);
the two packages share the same safety boundary but do not share runtime code.

## Install

    gem "openai-compatible-errors"

Then:

    bundle install

Ruby 3.0 or newer is supported. The gem has no runtime dependencies, so it can
sit at the boundary of a Net::HTTP, Faraday, HTTPX or OpenAI-style client
without forcing a transport choice.

## Normalize a failure safely

The normalizer accepts a response-like hash, a response object exposing
status/status_code, headers and body, or an exception carrying a nested
response. Provider-controlled text is not copied into the result by default.

    require "openai_compatible_errors"

    error = OpenAICompatibleErrors.normalize_error(
      status: 429,
      headers: {
        "retry-after" => "2",
        "x-request-id" => "req_demo_01"
      },
      body: {
        "error" => {
          "type" => "requests",
          "code" => "rate_limit_exceeded",
          "message" => "provider detail"
        }
      }
    )

    error.category         #=> :rate_limit
    error.status           #=> 429
    error.retry_after_ms   #=> 2000
    error.request_id       #=> "req_demo_01"
    error.provider_message #=> nil

    logger.warn(error.to_log_h)

The returned ApiError has stable library-owned message text and only validated
identifiers. It never has a body, headers, exception cause, traceback, prompt
or generated-output field. If an operator genuinely needs provider text, opt in
explicitly; common bearer and API-key formats are still redacted and the value
is bounded:

    diagnostic = OpenAICompatibleErrors.normalize_error(
      exception,
      include_provider_message: true
    )
    logger.warn(diagnostic.to_log_h(include_provider_message: true))

The opt-in is a risk reduction, not a guarantee that arbitrary provider text is
appropriate for a production log.

### HTTP and SDK adapters without dependencies

No client gem is required at runtime. A Net::HTTP response works directly:

    response = Net::HTTP::Post.new("/v1/responses")
    # ... perform the request ...
    error = OpenAICompatibleErrors.normalize_error(response)

For a client whose response object uses different names, pass the boundary
explicitly:

    error = OpenAICompatibleErrors.normalize_error(
      exception,
      status: response.status.to_i,
      headers: response.each_header.to_h,
      body: response.body
    )

Classification prefers HTTP status, structured error.code/error.type and
exception class names. Free-form exception messages are not retained and are
only a last-resort signal for transport categories.

Supported categories are authentication, permission, rate_limit, quota,
conflict, validation, not_found, payload_too_large, timeout, network,
upstream, server, schema, endpoint, aborted, stream and unknown. A 409
conflict intentionally does not become an automatic retry: the library cannot
infer how the application should resolve state.

## Plan retries, never replay blindly

An HTTP method does not prove that a request is safe to replay. Supply the
operation's replay contract and the phase in which it failed:

    context = OpenAICompatibleErrors::RetryContext.new(
      method: "POST",
      phase: :http_error,
      replay_safety: :safe,
      # caller-owned operation contract, not a guess from the verb
      attempt: 1,
      elapsed_ms: 350
    )

    plan = OpenAICompatibleErrors.decide_retry(error, context)

    case plan.action
    when :retry
      schedule_retry_after(plan.delay_ms || 0) # your scheduler owns the wait
    when :do_not_retry
      fail_request(error)
    when :manual_decision
      ask_the_application_for_more_evidence
    end

retry is returned only for a transient category, known replay-safe operation,
known phase, no observed stream output and remaining attempt/time budgets.
do_not_retry covers permanent failures, unsafe replay, cancellation,
completion, partial output and exhausted budgets. manual_decision means the
evidence is incomplete or unclassified.

Server Retry-After and millisecond hints are parsed without network calls.
Duplicate hints use the longest valid delay. A malformed present hint becomes a
bounded sentinel, so the default policy fails closed rather than replacing a
server instruction with a short local retry. Local exponential backoff supports
full jitter and an injectable random function for deterministic tests:

    policy = OpenAICompatibleErrors::RetryPolicy.new(
      max_attempts: 4,
      max_elapsed_ms: 20_000,
      jitter: :none
    )
    plan = OpenAICompatibleErrors.decide_retry(error, context, policy: policy)

The library never sleeps, opens a socket, calls a provider or replays a
request.

## Inspect streaming replay boundaries

SSEInspector consumes byte chunks incrementally. It handles CRLF/LF framing,
UTF-8 split across network chunks, Chat Completions deltas, Responses event
names, [DONE], provider error events and unexpected EOF. It records state only:

    inspector = OpenAICompatibleErrors::SSEInspector.new

    response.each_body do |chunk|
      inspector.feed(chunk)
      consume_chunk(chunk) # the application decides what to render
    end

    state = inspector.close
    if state.unexpected_eof? && state.has_output
      # The provider may already have produced billable/user-visible output.
      raise "stream ended after partial output; do not replay automatically"
    end

For an Enumerable, the helper preserves one-at-a-time iteration and yields
each original chunk before asking for the next:

    state = OpenAICompatibleErrors::SSEInspector.inspect_each(response_enum) do |chunk|
      render(chunk)
    end

Terminal states are done, incomplete, error and unexpected_eof. has_output is
intentionally conservative: a false positive merely prevents an unsafe replay,
while a false negative could duplicate output or billing. The inspector never
stores generated text or a complete response body.

## Bounded log sanitization

Use sanitize_for_log for small diagnostic context, not as a data-retention
policy:

    safe = OpenAICompatibleErrors.sanitize_for_log(
      { "provider" => "example", "api_key" => ENV["API_KEY"], "attempt" => 2 }
    )

It redacts sensitive key names and common credential formats, limits depth,
nodes, keys, items and characters, and breaks cycles. Exception messages are
never traversed. Keep real credentials, prompts, completions and customer
payloads out of fixtures and logs.

## Compatibility and boundaries

This gem targets common OpenAI-compatible shapes used by gateways, self-hosted
routers and SDK adapters. It is not an OpenAI product, provider certification
or promise of complete parity with any vendor's proprietary event schema.
Unknown data-bearing SSE events are treated conservatively because replaying
after an unrecognized event can duplicate visible output.

Use a full resilience library when you need circuit breaking, cancellation-aware
sleep, hedging or request execution. Keep a provider SDK's native exception when
one stable provider contract is all your application needs.

## Related language packages

- [JavaScript and TypeScript package on npm](https://www.npmjs.com/package/@ai-router/openai-compatible-errors)
- [Python package on PyPI](https://pypi.org/project/openai-compatible-errors/)
- [.NET package on NuGet](https://www.nuget.org/packages/AiRouter.OpenAICompatibleErrors/)
- [JVM contract package on Maven Central](https://central.sonatype.com/artifact/dev.ai-router/openai-compatible-contract-junit)
- [Rust stream guard on crates.io](https://crates.io/crates/llm-stream-guard)

## Development

    bundle install
    bundle exec rake test
    gem build openai-compatible-errors.gemspec

See CONTRIBUTING.md, SECURITY.md and RELEASING.md for the test boundary and
token-free release process.

MIT licensed.
