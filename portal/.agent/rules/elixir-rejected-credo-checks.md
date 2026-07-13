# Rejected Credo checks (spiked, measured, not wired)

Candidate AST checks the taste pipeline evaluated and **deliberately did not
add**. Recorded so they don't get re-proposed each time the audit-sweep smells
resurface — and so a future proposal starts from the measured false-positive
evidence below, not from scratch.

The bar (`portal/AGENTS.md` → Enforcement): "Adding a rule = adding its check"
applies to a rule that is *mechanically decidable with low false-positives*. A
candidate that fires mostly on correct code trains people to ignore it or
sprinkle `# credo:disable`, which is worse than no check — those belong to
`/iron-review` judgment, not a standing AST check.

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
clean rule to encode. **Verdict: `/iron-review` judgment, not a Credo check.**

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

---

**If reopened:** re-measure first (the prototype for #1 was a path-scoped
prewalk matching `{:=, _, [ok_tuple, remote_call]}`). A check is only worth
wiring if it fires on the *bug* and not the *idiom* — fixture-verify both the
true-positive AND a representative idiom-negative before adding it.
