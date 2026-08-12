# symbolicator

Debugging native crashes with [Symbolicator](https://github.com/getsentry/symbolicator),
Sentry's native symbolication service, and keeping the host it runs on healthy.

| ID                                    | Mutation    | Risk |
| ------------------------------------- | ----------- | ---- |
| `symbolicator.symbolicate`            | none        | low  |
| `symbolicator.symbolicate_minidump`   | none        | low  |
| `symbolicator.symbolicate_apple_crash`| none        | low  |
| `symbolicator.health`                 | none        | low  |
| `symbolicator.version`                | none        | low  |
| `symbolicator.request_status`         | none        | low  |
| `symbolicator.cache_usage`            | none        | low  |
| `symbolicator.cleanup_preview`        | none        | low  |
| `symbolicator.cleanup`                | cache_state | medium |
| `symbolicator.config_show`            | none        | high |

## Reading symbols, never writing them

Symbolicator has no ingest endpoint: symbols reach it only from the sources an
operator configured (S3, GCS, HTTP, filesystem). Nothing in this pack — and
nothing a caller can send through it — publishes, alters, or deletes a symbol.
The three symbolicate actions are the read side: they hand the service a crash
and get back resolved frames.

That guarantee needs one deliberate defense. Symbolicator lets a request carry
its own `sources` block, and a source is a URL the host would then fetch — so
`symbolicate` rebuilds the request body from exactly `options`, `modules`, and
`stacktraces`. A `sources` key in the payload is dropped, which means the
answer always comes from the operator's configured sources and a caller cannot
point this host at a server of their choosing. A behavior case sends an
injected source and asserts it never reaches the service.

The two file actions take a path on the host — a dump systemd-coredump kept, a
`.crash` pulled off a device — contained to the directories crash artifacts
land in. Long-running work answers with a request id to follow through
`symbolicator.request_status`.

This pack drives the **service on a host**. For the Sentry API — issues,
releases, ingest keys — use the `sentry` pack; the two do not overlap.

## The disk is the operational story

Symbolicator caches downloaded debug files and everything derived from them,
across thirteen caches that grow at very different rates. `cache_usage` sizes
each one largest-first with the filesystem underneath, because one oversized
cache is the answer far more often than the total is.

`cleanup` is Symbolicator's own routine maintenance: it removes entries past
the retention windows in the configuration, not everything. Preview it first —
`cleanup_preview` runs the same pass with `--dry-run` and reports retained and
removed bytes per cache, so the decision is made on numbers. What a cleanup
removes gets re-downloaded from the symbol sources the next time it is needed,
so the cost is bandwidth and slower symbolication, not lost data.

## Why config_show is high risk

Symbolicator's `sources` block is operator-authored and routinely carries S3,
GCS, or HTTP credentials. Credential-shaped keys are masked on the way out, but
the key space belongs to the operator, so a credential under a name we do not
model would reach the caller. That is an open key space, and an open key space
is high — not medium behind a redaction pattern.

## Where it runs

The CLI actions need the `symbolicator` binary on the host, so a deployment
that only runs it in a container is deliberately not suggested this pack — the
`docker` pack already reaches into containers. The HTTP reads work either way,
against whatever `SYMBOLICATOR_URL` points at.

Symbolicator's API is unauthenticated by design; it expects to be reachable
only from Sentry's own network. These actions inherit that posture rather than
adding to it.
