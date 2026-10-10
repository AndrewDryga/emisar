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

**Exact public metadata exception.** The built-in JSON field rule preserves
`id_token_signing_alg_values_supported` and
`token_endpoint_auth_methods_supported`, the two public OIDC discovery fields
qualified by `oidc.discovery` behavior cases. This is a case-sensitive allowlist,
not an exemption for every `_supported` suffix. Credential fields such as
`client_secret_supported` still mask. The allowed fields' values still pass
through all credential and authored rules, including nested-field masking.

**Why.** The runner's `json-secret-field` and `secret-assignment` default
redaction rules rewrite any string under a secret-named key to `[REDACTED]`
before output leaves the host — unconditionally, with no entropy or value
check. A pagination token projected as `next_page_token` therefore reaches
the model as `[REDACTED]` on every page, and paging past page one is
impossible; the action looks green in any test that only asserts a null
cursor. Fail-closed redaction is correct — the fix is naming, never weakening
the rules.

**Messages too.** A script's own error text never puts a secret-named
variable right before `:` or `=`, because `secret-assignment` masks the next
word. `: "${EMQX_API_KEY:?is not set}"` makes sh print `EMQX_API_KEY: is not
set`, which reached operators as `EMQX_API_KEY: [REDACTED] not set` (emqx
0.1.0). Name the variable, then say what is wrong in a sentence
(`EMQX_API_KEY is empty.`). The runner passes a variable that
`execution.inherit_env` lists even when it is empty, so tell unset
(`${VAR+set}` is empty: allowlist it) from empty (give it a value) instead of
always blaming the allowlist.

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
and check each against a behavior case with a non-null value. For messages,
list `${VAR:?…}` and `${VAR?…}` guards in pack scripts whose `VAR` matches the
same regex (on 2026-09-26 only emqx had them).

**Enforced.** Behavior cases that assert real cursor values fail on
`[REDACTED]` (this is how the databricks suite caught it), and emqx's
`nodes-missing-secret` case asserts its whole sentence. Not yet a
mechanical authoring check — graduating it means scanning output-schema
property names and script guards against the same vocabulary in the pack
validator.
