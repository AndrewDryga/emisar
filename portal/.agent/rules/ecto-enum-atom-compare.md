# Rule: compare an `Ecto.Enum` field on its atoms, never a string literal

**Rule.** An `Ecto.Enum` field loads as an **atom** (`:sent`, `:published`,
`:pending`). Compare it against atoms — `@run.status in [:sent, :running]`,
`request.status == :pending` — never a string literal. A string comparison
(`@run.status in ["sent", "running"]`) is **always false** and fails silently:
no error, no warning, the branch just never fires.

**Why.** This shipped a real, costly bug (`69d9871`): `run_detail_live` guarded
the cancel button, the approval banner, and output-hiding with
`@run.status in ["sent", "running"]` — string literals against the atom field.
Every guard was dead, so none of those elements ever rendered, and nothing
flagged it. The web layer is the trap: the schema/context reads the atom and
compares atoms, but a LiveView author reaching for `"sent"` (what the wire/JSON
shows) writes a comparison that compiles clean and never matches.

Applies to every `Ecto.Enum`: run/approval/runbook `status`, membership `role`,
action `risk`, pack `trust_state`, policy/scope `scope_type`, run `source`,
event `kind`. The two deliberate `:string` look-alikes — `Subscription.status`
and `Account.plan` (see §3) — DO compare as strings; know which you hold.

**✅ Good**

```elixir
:if={@run.status in [:sent, :running]}
<%= if @request.status == :pending do %>
# or normalize to a string at the edge — don't compare against one:
{String.capitalize(to_string(@run.status))}
```

**❌ Bad**

```elixir
:if={@run.status in ["sent", "running"]}   # atom field vs strings → always false, silently dead
<%= if @request.status == "pending" do %>    # never true
```

**Enforced.** Review + grep, not Credo. A reliable AST check can't tell an enum
`.status` from the deliberate string `Subscription.status` without type
inference, so a generic check would false-positive on the string fields (and a
noisy check just trains disables). Sweep and read each hit:

```
grep -rnE '\.(status|role|risk|trust_state|scope_type|source|kind)\b *(==|in)[^]]*"' apps/emisar_web
```

A **dotted access on a schema enum field** compared to a string literal is the
bug; a bare local var (`status = string_field(run, …)` in the MCP renderer), a
function-head pattern fed a string (`derived_status/1`), or a deliberate
`:string` field is fine.
