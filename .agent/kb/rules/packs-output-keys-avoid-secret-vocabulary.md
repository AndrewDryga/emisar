# Rule: model-visible output keys avoid the secret vocabulary

**Rule.** A key in an action's structured output never uses a word from the
runner's secret-name vocabulary — `token`, `secret`, `password`/`passwd`/`pwd`,
`key` compounds (`api_key`, `access_key`, `signing_key`, …), `credential`,
`dsn`, `connection_string`, and the rest of `secretName` in
`runner/internal/redact/rules.go` — including as a `[._-]`-joined segment.
Name pagination continuations `next_page_cursor` (arg side: `page_cursor`),
never `next_page_token` or `continuation_token`. When a non-secret value
genuinely must ship under such a name, prove it with a behavior case that
asserts the real value round-trips unredacted.

**Why.** The runner's `json-secret-field` and `secret-assignment` default
redaction rules rewrite any string under a secret-named key to `[REDACTED]`
before output leaves the host — unconditionally, with no entropy or value
check. A pagination token projected as `next_page_token` therefore reaches
the model as `[REDACTED]` on every page, and paging past page one is
impossible; the action looks green in any test that only asserts a null
cursor. Fail-closed redaction is correct — the fix is naming, never weakening
the rules.

**✅ Good.**

```yaml
# databricks list actions: arg page_cursor, output next_page_cursor
next_page_cursor: {type: [string, "null"], maxLength: 2048}
```

with a behavior case asserting a non-null cursor value:

```yaml
- name: databricks.catalogs_list-follows-the-cursor
  action: databricks.catalogs_list
  args: {page_cursor: uc-page-2}
  expect:
    json:
      /catalogs/0/name: archive
```

**❌ Bad.** Projecting the API's wire name straight through
(`next_page_token: (.next_page_token // null)`) — the wire READ is fine, the
emitted KEY is what redaction matches; fixtures whose cursors are always null,
which hide the rewrite; renaming an arg to dodge the authoring lint while the
output keeps the secret-named key.

**Sweep.** For every pack with a `parser: json` output schema, list property
names matching the `secretField` regex in `runner/internal/redact/rules.go`
and check each against a behavior case with a non-null value.
`pure-flasharray` was the known instance — it shipped `continuation_token`,
now renamed to `next_page_cursor`
(task `2026-08-11-pure-flasharray-rename-continuation-token-output`).

**Enforced.** Behavior cases that assert real cursor values fail on
`[REDACTED]` (this is how the databricks suite caught it). Not yet a
mechanical authoring check — graduating it means scanning output-schema
property names against the same vocabulary in the pack validator.
