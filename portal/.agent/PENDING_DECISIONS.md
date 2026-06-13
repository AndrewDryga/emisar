# portal — PENDING DECISIONS

Things blocked on a human call (a product decision, an ambiguous spec, a
one-way-door migration). Each entry: **the decision · the options · my
recommendation**. The matching task in `TASKS.md` is marked `[B]`. Never guess on
an irreversible choice — write it here and move on. See root `AGENTS.md`.

## Open

- **Self-approval — keep it allowed?** Today a user holding the approve permission
  can approve their own action request. This is a deliberate product choice today,
  not a bug.
  - Options: (a) keep — fast for solo operators; (b) forbid self-approval — stronger
    separation of duties, requires a second approver.
  - Recommendation: keep for now; revisit when a customer needs SoD. *(Decision only,
    no task queued — flagged so a change is never made silently.)*
