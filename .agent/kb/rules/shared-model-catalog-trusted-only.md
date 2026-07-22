# shared: model catalogs expose only trusted pack refs

**Rule.** Every model-facing discovery surface exposes only exact pack refs
whose account, pack ID, version, and hash have a current operator-trusted,
complete manifest and are not retirement-blocked. Filter them at the shared
catalog projection before deriving actions, runner compatibility, runbooks,
version skew, issues, or continuations.

Pending, rejected, revoked, missing, hash-mismatched, incomplete, and retired
refs are operator-only facts. Show them on the Packs page and in audit history,
not as empty model-visible packs or diagnostic issue codes. Recheck trust and
retirement inside every mutation transaction even when discovery was trusted.

Good: `list_packs(availability: "all")` includes a trusted but offline pack for
deployment diagnosis, while the same ref disappears from all MCP catalog and
runbook surfaces immediately after trust is revoked. A stale direct dispatch
returns the shared hidden-contract error without persisting work.

Bad: return an untrusted pack with an empty action list and a `pack_untrusted`
issue; filter only the final `list_packs` response; or rely on dispatch rejection
after action search and runbook discovery already revealed the ref.

**Sweep target.** Search model-facing pack, runner, action, runbook, planning,
and execution catalogs for projections built from runner advertisements. Verify
that filtering precedes all derived results and that direct mutations still
gate the exact trusted ref in their transaction.

**How it is enforced.** MCP integration tests exercise pending, trusted, and
revoked transitions across pack, action, runner, runbook, and direct-dispatch
tools. Portal context tests continue to pin transaction-time trust and
retirement denial.
