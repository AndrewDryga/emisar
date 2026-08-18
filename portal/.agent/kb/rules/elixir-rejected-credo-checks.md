# Rejected Credo checks (spiked, measured, not wired)

Candidate AST checks the taste pipeline evaluated and **deliberately did not
add**. Recorded so they don't get re-proposed each time the audit-sweep smells
resurface — and so a future proposal starts from the measured false-positive
evidence below, not from scratch.

The bar (`portal/AGENTS.md` → Enforcement): "Adding a rule = adding its check"
applies to a rule that is *mechanically decidable with low false-positives*. A
candidate that fires mostly on correct code trains people to ignore it or
sprinkle `# credo:disable`, which is worse than no check — those belong to
`/elixir-iron-review` judgment, not a standing AST check.

---

## 1. Assertive `{:ok, _} = <Context>.<fn>(...)` in a LiveView/controller

**The smell (H2/M4/L3 class, audit-sweep 2026-06-17).** A web-layer call that
match-asserts a context result with `=` on a path that can return
`{:error, …}` crashes the LiveView/controller instead of handling the error.

**Why rejected — measured ~100% false-positive.** A prototype
(`{:ok, _} = Alias.fn(args)` in `apps/emisar_web/lib/`) fired on **32 sites**,
and nearly every one is the **accepted house idiom**, not a bug:

- post-gate reads — `{:ok, rows, _} = Runners.list_*_for_account(subject)`,
  `Catalog.list_all_actions_for_account/1`, `Approvals.list_pending_…/2`. The
  LiveView already gated `mount`, so the `{:error, :unauthorized}` arm is an
  unreachable invariant the developer correctly asserts away.
- post-gate writes — `ApiKeys.revoke_api_key/2`, `Runners.delete_runner/2`,
  `Accounts.record_account_switched/1`.
- the inbound SCIM controllers — `SSO.scim_upsert_group/2` etc. (already
  authenticated by the `ems-` bearer).
- third-party / stdlib — `YamlElixir.read_from_file/1`, `Plug.Conn.read_body/2`.

An AST check **cannot** distinguish a *reachable, mishandled* error path (the
specific bugs the audit found, since fixed) from an *invariant-OK* post-gate
read without dataflow/semantic analysis. The team's code shows
`{:ok, …} = Context.read(subject)` is the deliberate convention, so there is no
clean rule to encode. **Verdict: `/elixir-iron-review` judgment, not a Credo check.**

## 2. A context fn counting (`length`/`Enum.count`) over a `Repo.list/3` result

**The smell (H1 class).** `Repo.list/3` is paginated and returns
`{:ok, rows, %Metadata{}}` where `rows` is **one page**; counting `rows` yields
the page size, not the total.

**Why rejected — zero current occurrences + needs intra-function dataflow.**
Every `length`/`Enum.count` in `lib/emisar/*.ex` today counts an *in-memory*
list or a `Repo.all` result (`owners` for the last-owner guard, `work_list` /
`runs` / `runner_ids` in runbook dispatch, SCIM `added`/`removed`, MFA recovery
codes) — **none** count a `Repo.list` page. To fire only on the bug shape the
check must track a variable bound from the `Repo.list` 3rd tuple element and
flag a later `length(var)`/`Enum.count(var)` on it; a naive "count + `Repo.list`
in the same file" check flags all 8 files that legitimately count. That is high
build-complexity and medium false-negative risk guarding a shape that does not
recur. **Verdict: not worth a standing check; covered by review + the paginated
return-shape (IL-5) being explicit.**

## 3. `String.upcase/downcase` on a value that reaches a template

**The smell (manual-compaction sweep, 2026-08-08).** The casing rule says an
entity identifier renders exactly as authored, and that a `String.upcase/1` in
Elixir is worse than the CSS class because it spells one identifier two ways on
one screen. The bullet's stated sweep is "`String.upcase`/`String.downcase` on a
value that reaches a template".

**Why rejected — measured 32 occurrences, 32 false positives.** Every
`String.up/downcase` in `apps/emisar_web/lib` today is *normalization for
comparison or search*, not a value transform on rendered text:

- the four that reach a template at all are `data-*` attributes feeding
  client-side filtering — `data-search={String.downcase(@blank_label)}`
  (`core_components.ex:498`), `data-filter-search=` (`runbook_workflow_components.ex`
  ×2), `data-pack-name=` (`packs.html.heex:102`). None is displayed text.
- the rest are comparison keys: redaction header matching (`application.ex`),
  user-agent sniffing (`plugs/analytics.ex`), UTM normalization
  (`marketing_attribution.ex`), SCIM filter parsing, MCP catalog search, and the
  case-insensitive **entry codes** the rule explicitly legalizes
  (`user_session_controller.ex`, `magic_link_live.ex`, `activate_live.ex`).

Deciding "does this value reach rendered text?" needs dataflow from the call to
a HEEx text node; an AST check sees only the call. Firing on all 32 correct sites
is exactly the train-people-to-ignore-it failure. **Verdict:
`/elixir-iron-review` judgment, not a Credo check.**

## 4. `whitespace-pre-wrap` on a multiline-formatted element

**The smell (same sweep).** Template indentation inside a pre-wrap element
renders as real leading whitespace, so the value must ride a glued one-line
inner `<span class="whitespace-pre-wrap">{@value}</span>`.

**Why rejected — needs a HEEx tree, and the crude form is mostly noise.** Of 39
`whitespace-pre-wrap` uses in `apps/emisar_web/lib`, a line-window heuristic
("interpolation on its own line within 2 lines after the class") surfaces 2, and
neither is decidable without knowing whether the interpolation is that element's
*child* or a nested element's. Getting it right means parsing the HEEx tree to
attach the class to its element and inspect that element's children — real
parser work for a rule with no current violations and a cosmetic failure mode.

Note this one could not be a Credo check even if it were decidable: Credo cannot
parse `.heex` (it drops the file as unparseable), so like the anchor-glue and
repeated-inline rules it would belong in `EmisarWeb.TemplateHygieneTest`.
**Verdict: deferred — revisit only if it recurs, and then build it on a real
HEEx parse, not a line window.**

## 5. An ETF compression guard (`<<131, 80, _::binary>>`) paired with a byte bound

**The smell (CVE-2026-69659 follow-up, 2026-08-10).**
`Emisar.Checks.NoUnsafeDeserialization` flags every ETF decode, but the escape
hatch it documents — a `# credo:disable-for-next-line` over a decode that is
genuinely unavoidable — carries a two-part contract the check that fired cannot
see: refuse compressed payloads (`<<131, 80, _::binary>>`) *and* bound the raw
byte size. The proposal was a second, standalone check asserting that contract —
a module matching the ETF magic bytes must also bound its input's size.

**Why rejected — the co-occurrence heuristic is satisfied incidentally.** The
contract is not decidable from the call site (that is *why* it is prose in the
first check), so the only module-local approximation is "the ETF pattern and a
`byte_size` bound appear in the same module". Measured in portal `lib/`: **0**
`<<131` patterns and **86** `byte_size` call sites across **36** of 429 modules —
MCP service framing, `raw_json`, command previews, run-output truncation,
attestation. Any module that ever needed the guard would be a parsing/transport
module, i.e. exactly the class that already bounds sizes for unrelated reasons —
`Emisar.Repo.Paginator`, the closest real analogue we have, carries five. So the
check would pass whether or not a bound ever governs the decoded input. Proving
the real property — that a bound applies to *this* value before *this* decode —
needs dataflow, not a prewalk.

A security check that can be satisfied by an unrelated line elsewhere in the file
is worse than no check: it reads as enforcement while providing none. **Verdict:
the contract stays prose in `NoUnsafeDeserialization`'s `explanations:` block,
where the developer writing the disable comment reads it (`mix credo explain`),
and the disable comment itself is the review anchor.**

## 6. Every `x["key"] != []` emptiness guard

**The smell (`Protocol.UndefinedError` in production, 2026-08-12).** `nil == []`
is `false`, so an emptiness guard on a map read passes when the key is absent
and hands the comprehension behind it a nil. The run page's inputs grid did
exactly that and raised `Enumerable not implemented for Atom` on every render
of a runbook whose stored definition predated the `"inputs"` key — 49 events,
the whole page down. The rule is
[`elixir-nil-is-not-an-empty-list.md`](elixir-nil-is-not-an-empty-list.md).

**Why the broad form was rejected — measured 11/11 false-positive.** A prototype
flagging `x["key"] != []` / `== []` fires on 11 sites in `apps/emisar_web/lib`,
and **every one is correct**:

- `runbook_editor_components.ex` ×3 and `runbook_workflow_components.ex` ×8 —
  all read a **draft**, and `RunbookDraft.from_definition/1` normalizes
  `"inputs"`/`"stages"` with `|| []` before the components ever see it. The key
  is present by construction, so comparing to `[]` is the right check.

The comparison is not the defect; reading an **un-normalized** map is. An AST
check cannot tell a stored `jsonb` column from a constructor's output without
dataflow, so it would fire on the idiom and never on the bug — the exact
failure mode this file exists to prevent.

**What was wired instead.** The narrow, decidable shape: a `:for` walking the
same raw subscript expression its enclosing element compares to `[]`. Those two
expressions must agree about one value and only one of them handles nil, which
is decidable from source text with no dataflow. It lives in
`EmisarWeb.TemplateHygieneTest` ("a comprehension does not re-read a raw
subscript its guard already tested") because Credo cannot see inside a `~H`
sigil — the template body is a binary literal at parse time, and the production
crash was inside one. Fixture-verified both ways: it fires on the original
buggy markup and stays silent on the normalized form and on the 11 draft sites.
**Verdict: broad AST check rejected; narrow template check wired.**

## 7. `match?/2` on a struct field value

**The smell (readability sweep, 2026-08-18).** A value whose contract already
guarantees `%RunnerAccess{}` was read through guarded patterns such as
`match?(%RunnerAccess{mode: mode} when mode != :none, access)`. The code was
only comparing fields, but made the reader parse a shape test and a guard.

**Why the broad form was rejected — shape is sometimes the real question.** The
production tree initially carried eight `match?(%Struct{...}, value)` sites.
Six field-value conditionals became clearer as direct field reads or explicit
`case` dispatch. The other two are deliberate shape filters: one pipeline
accepts either an invalid changeset or nil, and one web collection accepts a
loaded `%Runbook{}` among values that may not be a runbook. A prewalk can see
the struct pattern but cannot know whether the value's upstream contract
guarantees that struct. Flagging both idioms would either create standing noise
or force a verbose `case` where `match?/2` says exactly what is being tested.

**Verdict:** keep the direct-field rule in `portal/AGENTS.md` as review judgment.
The existing `MatchOnMapFieldValue` check stays intentionally narrower because
bare-map field matches can silently survive a schema move; a struct pattern at
least validates its named fields at compile time.

---

**If reopened:** re-measure first (the prototype for #1 was a path-scoped
prewalk matching `{:=, _, [ok_tuple, remote_call]}`). A check is only worth
wiring if it fires on the *bug* and not the *idiom* — fixture-verify both the
true-positive AND a representative idiom-negative before adding it.
