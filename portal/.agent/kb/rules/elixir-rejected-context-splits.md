# Rejected context splits (measured, not done)

Context extractions that an audit proposed and a measurement **deliberately did
not carry out**. Recorded so the same smell — a long context module — does not
get re-proposed from line count alone each time a sweep runs.

The bar (`portal/AGENTS.md` → the layered-context shape): a context is a
boundary. Splitting one is worth it when the two halves are genuinely separate
domains, which shows up as the halves sharing almost no private helpers. When
they share many, the split does not remove coupling — it converts private calls
into cross-context ones and adds an authorizer that has to defer to the other
side. That is more surface, not less.

---

## 1. `Emisar.Directory` extracted from `Emisar.SSO`

**The smell (tech-debt sweep, 2026-08-06).** `lib/emisar/sso.ex` is 4,032 lines
and 82 public functions. The proposal: the SCIM directory-sync half is a
separate bounded context — different callers (`EmisarWeb.SCIM.*` versus the
sign-in controller), a different auth model (a per-provider `ems-` bearer with
no `%Subject{}` at all), and its own four schemas (`DirectoryGroup`,
`DirectoryGroupMember`, `GroupRoleMapping`, `GroupRunnerAccessMapping`).

The argument is good on paper, and the file really is too long to hold in view.

**Why it was not done.** The seam does not exist in the code. Reachability was
computed over the module's private-helper call graph, from the public functions
of each half, at two different seam definitions:

| seam | Directory-side public fns | helpers only Directory reaches | helpers only the rest reaches | **shared** |
|---|---|---|---|---|
| `scim_*` wire surface only | 14 | 47 | — | **18** |
| `scim_*` + the group mappings | 24 | 60 | — | **24** |
| the audit's full band | 37 | 74 | 46 | **21** |

Narrowing the seam does not reduce the sharing; it stays around twenty either
way. Among the shared helpers are `ensure_can_manage_sso` — an **authorization**
helper, so the new context's authz would defer to the old one's —
`prepare_provider_authorization_change`, `provider_identities`, `peek_identity`,
`capture_link_request` and `capture_member_link`.

Every Directory function is also scoped by an `%IdentityProvider{}`, which stays
in SSO. A context whose every entry point pattern-matches another context's
struct and whose authorization defers to it is not a separate domain; it is the
same domain in two files.

Compare the split that WAS done in the same sweep,
`components/core_components.ex` → marketing/auth/domain/core: marketing and
domain shared **zero** helpers with another group and auth shared one. That is
what a real seam measures like.

**What was done instead.** The SCIM implementation moved into submodules of the
SAME context, with `Emisar.SSO` still the public boundary the web calls:

* `Emisar.SSO.SCIM` — the SCIM 2.0 wire surface and the 52 helpers only it
  reaches. `Emisar.SSO` keeps the fourteen public functions the SCIM
  controllers call and forwards to it, so no controller changed.
* `Emisar.SSO.Provisioning` — the twenty shared helpers, which turned out to be
  one coherent thing: resolving a synced member's role and runner access from
  the groups their provider reports. That is precisely why the context split
  did not work, and precisely why these belong together.

`sso.ex` 4,033 → 2,575 lines. No new authorizer, no cross-context calls, and
exactly one call back into `SSO` (`recompute_role_for_identity/2`, now
qualified). The public surface is byte-for-byte what it was.

If the remaining 2,575 lines become the problem, the OIDC sign-in half is the
next seam to measure — not to assume.

**How it is enforced.** Review. Do not re-propose the CONTEXT extraction from
the line count alone — bring the shared-helper measurement.
