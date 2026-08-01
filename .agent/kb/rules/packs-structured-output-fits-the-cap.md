# Rule: structured output fits the 8 KiB cap at its advertised worst case

**Rule.** An action that declares `output.schema` must produce a result whose
worst case fits the runner's structured-output cap (`MaxResultBytes` = 8192
bytes in `runner/internal/outputschema`, measured after canonical JSON
encoding). Size the worst case at authoring time from what the contract
advertises — the maximum `page_size`, the longest field values the upstream
API accepts, the full log tail — and bound whatever can grow without bound:
clip free text in the projection, cap list-page arguments so a full page of
worst-case entries fits, and declare the resulting `maxLength`/`maxItems` in
the schema. JSON escaping can double a clipped string's bytes (quote,
backslash, U+2028/U+2029), so byte arithmetic uses the encoded worst, not the
character count. A behavior case at the maximum advertised size against
worst-case fixture data is the proof: the runner enforces the cap, so the
case's success status is the byte-size assertion.

**Why.** The cap is enforced after the pack's own `max_stdout_bytes`, so a
pack can pass its stdout bound and still fail `validation_failed:
"structured output exceeds 8192 bytes"` — deterministically, on real data.
An LLM following the advertised argument range then gets a guaranteed
failure it cannot reason its way out of (the live `tfc.list_runs
page_size: 30` incident), and a single hostile free-text field (a run
message any VCS committer influences) can break a listing for everyone.

**Good.**

```yaml
- name: page_size
  type: integer
  default: 12
  validation: {min: 1, max: 12}   # 12 × worst-case entry + envelope < 8192
```

```jq
message: ($a.message | clipped(100; 160))   # codepoint AND byte bound
```

**Bad.**

```yaml
- name: page_size
  validation: {min: 1, max: 100}  # 100 × ~340-byte entries ≈ 34 KiB — can never fit
```

```jq
message: ($a.message // "")       # unbounded third-party text into a capped result
```

**Sweep.** For every action declaring `output.schema` (`rg -l '^\s+schema:'
packs/*/actions/*.yaml`), estimate the worst-case encoded result from the
schema and the projection: unbounded strings, arrays without a page cap, log
tails larger than the cap. Fix the projection and argument bounds, and add
the max-size behavior case.

**Enforced.** By the runner at dispatch (fail-closed), which is exactly why
the authoring-time proof matters: each pack's maximum-size behavior case in
`test/cases.yaml` runs the real runner, so an over-cap page turns the case
red in the pack CI matrix.
