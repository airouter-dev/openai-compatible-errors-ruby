# A production boundary for Ruby OpenAI-compatible API clients

OpenAI-compatible endpoints make it easy to point an existing Ruby client at a
gateway, self-hosted router or another provider. The difficult part starts when
the first request fails: a 429 can mean a short rate limit or exhausted
credits, a disconnected POST may already have reached the upstream service,
and an SSE connection can fail after user-visible tokens have been rendered.

This article explains the engineering boundary behind
openai-compatible-errors on RubyGems. The gem is intentionally small at
runtime (no HTTP client dependency), but it is not a blanket retry-everything
helper.

## Why status-code-only retry logic loses money

The following code is common:

    rescue => error
      sleep 1
      retry
    end

It collapses at least four separate questions:

1. Is the failure transient?
2. Did the server receive the operation?
3. Did the stream already expose output?
4. Is replay allowed by this operation's contract?

For a non-streaming idempotent lookup, a gateway 503 may be replayable. For a
generation POST that timed out after headers, replay can duplicate work or
charge twice. For SSE, replay after the first visible delta can duplicate text
in the UI. A useful Ruby error object therefore needs to preserve evidence
about the boundary, not the provider's entire body.

## A safe snapshot has a narrow data contract

normalize_error extracts only validated status, short identifiers, correlation
IDs and a bounded retry hint. Its ApiError message is library-owned text. Raw
JSON, authorization headers, prompts, completions and exception causes are
intentionally absent:

    safe = OpenAICompatibleErrors.normalize_error(response)
    logger.warn(safe.to_log_h)

This matters in shared logs. A provider may put a request fragment or an
accidental credential in an error message. The default object gives an
operator a stable category while preserving enough request metadata to find a
trace. Provider text requires an explicit opt-in and still passes through
credential redaction.

## Retry-After is evidence, not an order to sleep

The gem parses seconds, HTTP dates and millisecond hints, but it never sleeps.
The application owns cancellation and scheduling:

    plan = OpenAICompatibleErrors.decide_retry(error, context)
    schedule_retry_after(plan.delay_ms) if plan.retry?

Malformed server hints saturate to a bounded sentinel. That design is
deliberately conservative: silently turning Retry-After: soon into a 500 ms
retry could create a synchronized retry storm. The default policy also checks
the remaining elapsed-time budget and maximum delay.

## SSE needs a separate replay state machine

SSE is a sequence of framed events, not a JSON response. A parser that only
looks for [DONE] cannot distinguish an idle stream from one that emitted a
partial completion. SSEInspector keeps:

- protocol (chat_completions, responses or unknown);
- event and malformed-event counts;
- whether any delta or data-bearing event may have become visible;
- terminal state (done, incomplete, error or unexpected_eof).

It handles UTF-8 split across network chunks by buffering bytes until a frame
boundary, then discards the frame. Generated text is never retained:

    inspector = OpenAICompatibleErrors::SSEInspector.new
    stream.each do |chunk|
      inspector.feed(chunk)
      render(chunk)
    end
    state = inspector.close

An unknown data-bearing event conservatively sets has_output. Preventing one
automatic replay is cheaper than duplicating a user's answer or a billable
upstream generation.

## Where this gem stops

The library does not implement circuit breakers, hedging, sleeps, provider
authentication, request transport or billing policy. Those decisions belong to
the application that knows whether an operation is idempotent and whether the
user has seen output. It is compatible with Net::HTTP, Faraday, HTTPX and
OpenAI-style SDK objects because it depends only on Ruby's standard library.

If an application needs a complete resilience runtime, compose this package
with one. If it only talks to one provider with a stable native exception
contract, the provider SDK may be enough. The value here is the explicit,
auditable boundary when an application talks to multiple
OpenAI-compatible endpoints.
