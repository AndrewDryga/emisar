# symbolicator

Operating the host that runs [Symbolicator](https://github.com/getsentry/symbolicator),
Sentry's native symbolication service — liveness, build, the caches that fill
its disk, and one symbolication request's fate.

| ID                              | Mutation    | Risk |
| ------------------------------- | ----------- | ---- |
| `symbolicator.health`           | none        | low  |
| `symbolicator.version`          | none        | low  |
| `symbolicator.request_status`   | none        | low  |
| `symbolicator.cache_usage`      | none        | low  |
| `symbolicator.cleanup_preview`  | none        | low  |
| `symbolicator.cleanup`          | cache_state | medium |
| `symbolicator.config_show`      | none        | high |

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
