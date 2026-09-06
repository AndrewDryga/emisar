# Rule: argument bounds follow the backend's real limit

**Rule.** A numeric or duration maximum on an LLM-supplied action argument
comes from one of two places: the limit the backend actually enforces
(retention, an API maximum, a server-side resolution cap) or what bounds the
cost of one run (points per page, bytes, timeout). An arbitrary calendar span
such as "24h" or "7d" is not a bound; it is a guess that blocks legitimate
work while adding no safety.

**Why.** Each run is already bounded by `page_size`, `max_stdout_bytes`, and
`timeout`, and the backend rejects what it cannot serve. A span cap on top of
that only removes capability: the 24h cap on `gcp.metric_query` made a
two-week request-rate trend impossible while Google keeps that metric for 24
months and paginates a longer window into the same page size. An agent that
hits such a cap either gives up or looks for a bypass; the cap is a product
defect, not a safety feature.

**Good.**

```yaml
- name: window_minutes
  description: Trailing window in minutes ending now, up to 730 days (1051200).
  validation: {min: 1, max: 1051200}   # Google's metric retention
```

The description states the backend's retention and how to keep a long window
cheap (aligner and alignment period), so the agent chooses well on its own.

**Bad.**

```yaml
- name: window_minutes
  description: Recent query window in minutes.
  validation: {min: 1, max: 1440}      # copied from the logs action
```

**Exception.** A span cap is legitimate when the backend's scan cost grows
with the span and nothing else bounds it, such as a raw log search without a
row limit. Say so in the description.

**Sweep.** For every `validation.max`, `max_duration`, or "up to Nd" text on
a window, range, or lookback argument, name the backend limit or per-run bound
it mirrors. A cap that mirrors neither is raised to the backend's limit in a
routine version bump.

**Enforced.** Review only; the loader checks that a bound exists, not where it
came from.
