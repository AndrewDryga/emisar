# Rule: argument bounds follow the backend's real limit

**Rule.** The maximum on an LLM-supplied numeric or duration argument is
the smaller of two real limits: what the backend can serve (retention, an
API or server maximum) and what one Emisar run can carry (points per page,
bytes, the structured-output cap, the timeout). A generous round number is
acceptable as the top limit only when both real limits sit above it and no
operator would ask for more, and the description names the limit that binds.
A short calendar span or a small count chosen without either limit in view
("24h", "7d", "100") is a guess, not a bound, and is replaced.

**Why.** Each run is already bounded by `page_size`, `max_stdout_bytes`, and
`timeout`, and the backend rejects what it cannot serve. A guessed cap on top
of that only removes capability: the 24h cap on `gcp.metric_query` made a
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
A cap that mirrors an Emisar limit says so the same way: "up to 1000 points,
the size of one page".

**Bad.**

```yaml
- name: window_minutes
  description: Recent query window in minutes.
  validation: {min: 1, max: 1440}      # copied from the logs action
```

A window or limit hard-coded into the command with no argument at all is the
same defect with no knob: an action titled "last 1h" is a snapshot, not a
query, and needs a sibling that takes the window.

**Exception.** A span cap is legitimate when the backend's scan cost grows
with the span and nothing else bounds it, such as a raw log search without a
row limit. Say so in the description.

**Sweep.** For every `validation.max`, `max_duration`, duration `enum`, or
"up to N" text on a window, range, lookback, or limit argument, and for every
window or limit written into `argv`, name the backend limit or the Emisar
per-run bound it mirrors. A cap that mirrors neither is raised to the smaller
of the two in a routine version bump, and the description names the limit.

**Enforced.** Review only; the loader checks that a bound exists, not where it
came from.
