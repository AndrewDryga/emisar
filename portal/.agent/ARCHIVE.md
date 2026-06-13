# portal — ARCHIVE (migrated 2026-06-12 when .agent/ was introduced)

Completed work and resolved findings, preserved here so nothing is lost.
The live queue is TASKS.md; open human decisions are PENDING_DECISIONS.md.

---

## NIGHT_TASKS.md — all items completed

# Night tasks

Working TODO list (review feedback 2026-06-10 + full per-function audit).
Check items off as they land; every change = its own commit, gated green
(`mix compile --warnings-as-errors && mix format --check-formatted && mix test`).

## A. Quick fixes

- [x] **A1. `users.ex` `ensure_password_length/1` is redundant** — `User.Changeset.password/3`
  already validates length 12..128; drop the context pre-check (and the
  `@password_min_length` attr + stale `:passwords_must_match` doc), let the
  invalid changeset carry the error. Update callers/tests that match
  `{:error, :password_too_short}`. *(Done — profile_live already pre-validates
  via the form changeset and has an `{:error, _cs}` catch-all; the credential
  gate now runs before length validation, which is the right order for a
  probe-audit anyway.)*

## B. PubSub belongs to the contexts

- [x] **B1. Move topics + subscriptions into their owning contexts** (`pubsub.ex` L27-71):
  topic + `subscribe_*` for runs → `Runs`, approvals → `Approvals`, packs →
  `Catalog`, auth_keys/runners/per-runner → `Runners`, api_keys → `ApiKeys`,
  runbooks → `Runbooks`, team → `Accounts`, audit → `Audit`, per-run → `Runs`.
  Broadcast helpers move too — private inside the context when nothing
  outside calls them (most shouldn't be public). `Emisar.PubSub` keeps only
  the shared server/name plumbing.
- [x] **B2. `run:<id>` / `runner:<id>` topics** — check whether they need the
  `account:<id>:` prefix too; if it isn't too painful, add it.

## C. Product / UX

- [x] **C1. Invite accept + account-enforced 2FA**: today the new member gets a
  flash error ("2FA required") and a redirect to /app/settings/profile. If the
  account enforces MFA, show a second step of the invite-accept page instead —
  "this account requires 2FA" + enroll right there — then continue to the
  dashboard.
- [x] **C2. Runner name conflict on create**: replacing the old runner is fine
  as long as it's not active (connected). On conflict: old runner inactive →
  replace; active → keep rejecting.
- [x] **C3. Runbook run page** (`/app/runbooks/:id/run`):
  - dispatch on runner **groups** as well as individual runners (both work);
  - fix the post-Run UX: no redirect to the first run result — stay on one
    LiveView page that streams results in as they arrive (similar to the
    "Plan" list on that page, shorter rows + link to the full run).

## D. Investigations

- [x] **D1. Agent calling MCP sometimes stuck waiting forever** — investigate
  (suspects: `wait_for_run` long-poll without a server-side timeout, run never
  reaching a terminal state, PubSub subscribe race). Root cause, then fix.

## E. Performance

- [x] **E1. Runbooks can run steps in parallel**: v0.1 expansion is straight-line
  sequential but there are no conditions yet — batch steps (5-10 runs) and
  execute each batch concurrently.

## G. Cross-cutting conformance sweeps (the recurring review themes)

Codebase-wide checks for every rule class that came up in review — run each
sweep across `apps/emisar` (+ web where it applies), fix what it finds, zero
findings = done. These are the lenses to hold against every function in
section F too.

- [x] **G1. Context isolation** — no sibling builds another context's
  `<Schema>.Query` pipelines or `.Changeset`s (reads AND writes go through
  owning-context fns); only the documented exceptions (audit label/scope
  resolvers, workers on Query pipelines, web `filters/0`/known-value lists,
  struct matches, fixtures/seeds). Cross-context joins compose
  `Query.not_deleted()`, never raw schema modules.
- [x] **G2. Subject discipline** — IL-3 (`%Subject{}` last required positional
  arg of every public read/write), IL-4 (`for_subject` immediately before
  Repo), the **two-gates rule** (permission + `ensure_in_account` whenever a
  fn takes an entity + Subject), self-service reads actor from the Subject,
  internal no-Subject helpers are `@doc "Internal"` + account-scoped.
- [x] **G3. Permission-based authz only** — no `subject.role == :x` gating
  anywhere (covers_role?/has_permission? instead); no god-subject
  reintroduction (`:system` stays dead); web calls `subject_can_<verb>?`
  predicates, never maps UI→permission itself.
- [x] **G4. Fetch-then-mutate holds the row lock** — every fetch-and-write goes
  through `Repo.fetch_and_update/3` or fetches inside the Multi; no stale
  pre-transaction fetch followed by `Multi.update`.
- [x] **G5. Audit is domain-owned** — web/controllers/LiveViews/sockets never
  call `Audit.log*`; Multi-composed rows via `Audit.Events` builders;
  `Audit.log/3` only for fire-and-forget standalone events; actor derived via
  `Subject.actor_kind/actor_id`, never hand-assembled.
- [x] **G6. Soft-delete hygiene** — reads start at `not_deleted()`; every assoc
  to a `deleted_at` schema carries `where: [deleted_at: nil]` (belongs_to
  too); preloads via `with_preloaded_*` / `preloads/0` (no `preload:` opts
  when helpers exist); `Repo.preload` only inside the IL-10 exceptions.
- [x] **G7. Query-module conventions** — first arg `queryable`, named bindings,
  `by_x_id` takes id / no suffix takes struct, `with_*` reserved for
  join/preload, order helpers named by columns, position helpers own
  order+limit, `cursor_fields`/`filters`/`preloads` callbacks where used.
- [x] **G8. Changeset purity + casting** — IL-8 (zero `Repo.*`, incl. no
  `unsafe_validate_unique`), one fn per transition, `@fields` attrs,
  `Ecto.Enum` for fixed string sets, cast-first then `get_field` for guards
  (no hand-rolled `normalize_*`), field whitelists in `cast/3` not
  `Map.take/drop`.
- [x] **G9. Uniqueness + races** — DB unique index + `unique_constraint` +
  `Repo.Changeset.unique_constraint_error?/1` mapping (no per-context
  copies, no SELECT-then-INSERT prechecks); fetch-or-create =
  `on_conflict: :nothing` + re-fetch.
- [x] **G10. Bulk + existence** — N rows = one `insert_all` (validate-first,
  `Repo.generate_id/0`, `inserted_at`) unless deliberately per-row for error
  isolation (documented); existence via `Repo.exists?` (no count>0, no
  fetch-for-existence).
- [x] **G11. Crypto** — everything through `Emisar.Crypto` named minters;
  no inline `:crypto`/`Base` for secrets/digests in contexts; byte lengths
  live in Crypto.
- [x] **G12. Transactions** — `Ecto.Multi` + `Repo.commit_multi` over
  imperative `Repo.transaction(fn)`/`Repo.rollback` where feasible;
  txn-dependent reads inside `Multi.run`; side effects only in
  `after_commit`.
- [x] **G13. Style sweep** — no `= err` rebinding (restate literal / re-wrap
  reason); `do/end` when a `, do:` would wrap; no multiline pipes in clause
  heads or call args; `changeset` never `cs`; struct bindings named by schema
  (no `m`/`target`/`rb`); module header one contiguous block ordered
  use→import→alias→require, no blank after `@moduledoc`; no
  `DateTime.truncate(:microsecond)` helpers; no single-delegating `defp`
  wrappers; return only shapes callers consume; comments say why, not what.
- [x] **G14. Boundaries of the public surface** — forms are web-only
  (`change_*`, never `*_form` in a context); no test/seed-only fns in domain
  contexts (§7); tagged tuples only (IL-5); errors as values.
- [x] **G15. Tests** — every write has happy + denial + cross-account coverage;
  no `Process.sleep`; fixtures don't depend on context fns that exist only
  for them.

## F. Per-function audit (every context, every function) — REDO

Pass 1 was grep-driven and missed line-level violations (`Request.Query.all()`
assumption, `sup` shorthand). PROTOCOL for pass 2: for EACH function, read its
full body and walk EVERY rule below against it, in order, fixing violations
immediately (unfixable → NEEDS-REVIEW.md). Only after all rules pass may the
function's box be ticked. No greps as a substitute for reading the function.

PASS 3 (2026-06-10 evening): pass 2's eyeball reads missed short names
(`pv` in catalog and ~40 more files) — reading normalizes familiar
shorthand. Fixed by a mechanical codebase-wide candidate-grep sweep
(`5139e94`): pv/req/rb/cs/ev/cb/tok/src/cid/dt/sub/sid + single-letter
binds → spelled out across BOTH lib trees; query-module NAMED bindings
([memberships: m]) stay (documented §2 idiom). Also closed ALL FOUR open
NEEDS-REVIEW items: invitation tokens hashed at rest + 7-day expiry +
corrective migration (`dfc4b7d`), OAuth consent audited (`ae4afc8`),
Paddle customer link first-wins under the row lock (`dfc4b7d`),
upsert_subscription decision documented in place. Zero short-name grep
hits, IL greps clean, 435 + 387 green.

RULES (distilled from CLAUDE.md — re-read the source when in doubt):
- R1  IL-1/2: queryable starts at Schema.Query.fun(); no inline DSL, no Repo.get*
- R2  reads start at not_deleted() when the schema has deleted_at (VERIFY the
      schema — don't assume); all() needs a why-comment; no-deleted_at schemas
      start at all()
- R3  IL-3: %Subject{} last required positional arg; permission check before DB
- R4  IL-4: for_subject immediately before Repo.fetch/list/fetch_and_update
      (documented exceptions only)
- R5  entity+subject ⇒ two gates (permission AND in-account)
- R6  subject+explicit account ⇒ scope by BOTH
- R7  self-service reads actor from subject; mutations re-read under lock
- R8  internal no-subject fns: @doc "Internal", account-scoped, never web-exposed
- R9  IL-5: tagged tuples only; lists are {:ok, rows, metadata}
- R10 IL-10: preloads via preloads/0 / with_preloaded_*; Repo.preload only in
      the internal post-commit exception
- R11 fetch-then-mutate holds the row lock (fetch_and_update or in-Multi fetch)
- R12 Multi + commit_multi over imperative transaction/rollback (documented
      per-row-isolation exceptions only)
- R13 reads a txn depends on go INSIDE the Multi
- R14 fetch-or-create = on_conflict :nothing + re-fetch
- R15 uniqueness = DB index + unique_constraint + shared error mapping; no
      SELECT-then-INSERT
- R16 N rows = one insert_all (validated first) unless documented per-row
- R17 existence via Repo.exists? — never count>0 or fetch-for-presence
- R18 audit rows via Audit.Events builders in the Multi; Audit.log only
      fire-and-forget; actor fields never hand-assembled; web never audits
- R19 crypto via Emisar.Crypto named minters only
- R20 cast-first then get_field for guards; whitelist via cast, not Map.take
- R21 mixed-permission updates: changeset-diff-aware permission list
- R22 IL-14: no String.to_atom on external input
- R23 naming: intent-named fns, ?-suffixed booleans, variables SPELLED OUT
      (no sup/cs/rb/m/q), struct-named bindings
- R24 return only shapes callers consume
- R25 no literal-tuple rebinding (= err); re-wrap {:error, reason}
- R26 with for happy path; no multiline pipe in clause heads or call args
- R27 `, do:` only when it fits one line
- R28 header block contiguous (use→import→alias→require); cross-context refs
      via top-level alias
- R29 comments say why, never what
- R30 one public fn = one job
- R31 no single-delegating defp wrappers
- R32 public fns have @doc with contract/permission/return where non-obvious
- R33 writes have happy + denial + cross-account tests; no test-only fns in
      production contexts
- R34 not dead code; actually needed
- R35 formatter-clean; Ecto.Enum for owned fixed sets (two documented string
      exceptions: Subscription.status, Account.plan)

### F1. Accounts

- [x] fetch_account_by_id
- [x] list_accounts_for_user
- [x] create_account_with_owner
- [x] update_account
- [x] change_account
- [x] suggest_unique_slug
- [x] list_memberships_for_account
- [x] list_account_memberships
- [x] fetch_membership_for_session
- [x] record_account_switched
- [x] all_memberships_suspended?
- [x] update_membership_role
- [x] suspend_membership
- [x] reinstate_membership
- [x] force_password_reset
- [x] update_user_as_admin
- [x] end_all_sessions_for
- [x] delete_membership
- [x] invite_user_to_account
- [x] fetch_invitation_by_token
- [x] mark_invitation_accepted
- [x] accept_invitation
- [x] count_memberships
- [x] peek_account_by_paddle_customer_id
- [x] put_account_paddle_customer_id
- [x] subject_can_manage_team?
- [x] subject_can_manage_account_security?

### F2. Users

- [x] fetch_user_by_id
- [x] fetch_user_by_email
- [x] user_labels_for_ids
- [x] register_user
- [x] record_sign_in
- [x] update_user_profile
- [x] update_user_email
- [x] change_user_password
- [x] change_user
- [x] change_password
- [x] reset_user_password
- [x] mark_user_confirmed
- [x] update_user_mfa
- [x] put_user_mfa_recovery_codes
- [x] record_user_mfa_consumed
- [x] fetch_or_create_user_by_email
- [x] register_invited_user
- [x] update_user_profile_as_admin
- [x] clear_user_password

### F3. Auth

- [x] fetch_user_by_email_and_password
- [x] create_session_token!
- [x] fetch_user_by_session_token
- [x] delete_session_token
- [x] record_sign_out
- [x] record_failed_sign_in
- [x] delete_all_session_tokens
- [x] disconnect_and_revoke_all_sessions
- [x] revoke_and_disconnect_other_sessions!
- [x] broadcast_disconnect_for_user
- [x] live_socket_topic
- [x] live_socket_topic_for_session
- [x] list_sessions_for_user
- [x] revoke_session
- [x] revoke_other_sessions!
- [x] issue_magic_link_token!
- [x] consume_magic_link_token
- [x] issue_password_reset_token!
- [x] reset_user_password
- [x] issue_confirmation_token!
- [x] deliver_confirmation_instructions
- [x] confirm_user_by_token
- [x] generate_mfa_secret
- [x] enable_mfa
- [x] disable_mfa
- [x] regenerate_mfa_recovery_codes
- [x] mfa_required?
- [x] verify_mfa
- [x] consume_mfa_recovery_code

### F4. Runners

- [x] runner_labels_for_ids
- [x] list_runners_for_account
- [x] list_all_runners_for_account
- [x] list_group_summaries
- [x] fetch_runner_by_id
- [x] runner_active_in_account?
- [x] count_billable_runners
- [x] peek_runner_by_id
- [x] fetch_runner_by_external_id_for_account
- [x] create_runner — Accounts.Account alias (was fully-qualified)
- [x] disable_runner
- [x] enable_runner
- [x] delete_runner
- [x] apply_state
- [x] connect_runner
- [x] record_heartbeat
- [x] audit_runner_connected — R18 → Audit.Events.runner_connected
- [x] audit_runner_disconnected — R18 → Audit.Events.runner_disconnected
- [x] audit_runner_error — R18 → Audit.Events.runner_error
- [x] mark_disconnected
- [x] online?
- [x] connection_metas
- [x] subscribe_connections
- [x] connection_state
- [x] runner_scopes_for_membership
- [x] replace_runner_scopes
- [x] runner_scopes_for_membership_ids
- [x] runner_in_scope?
- [x] list_auth_keys
- [x] change_auth_key
- [x] create_auth_key
- [x] ~~create_auth_key_with_secret~~ — does not exist (stale entry)
- [x] mint_install_key
- [x] revoke_auth_key
- [x] peek_auth_key_by_secret
- [x] mint_runner_token
- [x] verify_runner_token
- [x] subject_can_manage_runners?
- [x] subject_can_manage_auth_keys?
- [x] register_via_auth_key — Repo.transaction → Multi; R18 audits → builders
- [x] (unlisted, walked clean: list_active_runners_in_group, deliver_to_runner, subscribe_account_auth_keys, subscribe_runner_transport)

### F5. Runs

- [x] list_runs
- [x] list_recent_runs
- [x] fetch_run_stats
- [x] list_recent_runs_for_runner
- [x] fetch_run_by_id
- [x] fetch_run_by_request_id_for_runner
- [x] create_run
- [x] dispatch_run — R18: check_pack_trust audit → Audit.Events builder
- [x] dispatch_run_for_account
- [x] list_stale_dispatches
- [x] dispatch_to_runner
- [x] cancel_run — R18: run.cancel_requested → builder
- [x] mark_sent
- [x] mark_running
- [x] mark_cancelled
- [x] mark_runner_unreachable
- [x] mark_finished
- [x] append_event
- [x] peek_run_by_id
- [x] fetch_run!
- [x] finalize_from_result
- [x] list_events_for_run
- [x] subject_can_dispatch_run?
- [x] subject_can_cancel_run?
- [x] (also walked clean: list_running_runs, list_runs_for_runbook_execution; log_policy_evaluated + log_grant_used R18 → builders)

### F6. Approvals

- [x] list_pending_approval_requests
- [x] count_pending_approval_requests
- [x] list_approval_requests_for_account
- [x] fetch_approval_request_by_id
- [x] fetch_approval_request_by_run_id — verified all() correct (Request has no deleted_at)
- [x] create_request
- [x] approve_request — R18 audit → Audit.Events.approval_approved
- [x] deny_request — R18 audit → Audit.Events.approval_denied
- [x] peek_matching_grant
- [x] use_grant
- [x] create_grant
- [x] revoke_grant
- [x] ~~list_grants_for_api_key~~ — does not exist (stale entry)
- [x] list_grants_for_account
- [x] fetch_grant_by_id
- [x] subject_can_decide_approval?
- [x] expire_overdue_requests — expire_one Repo.transaction → Multi; R18 audit → builder; require Logger to top

### F7. Catalog

- [x] observe_state — R18: insert_pinned/maybe_mark_pending audits → builders (Repo.transaction is the documented per-row exception)
- [x] trust_pack_version
- [x] reject_pack_version
- [x] fetch_pack_version_by_id
- [x] check_pack_trusted — R26 multiline pipe in case head → bound; dedup
- [x] trusted_hash_for_action — R26 + shared peek_pack_version_for_action
- [x] list_actions_for_runner
- [x] list_actions_for_account
- [x] list_all_actions_for_account
- [x] fetch_action_by_id
- [x] fetch_action_for_account
- [x] list_pack_versions
- [x] count_pending_pack_versions
- [x] subject_can_manage_packs?

### F8. Billing

- [x] plans
- [x] plan
- [x] upsert_subscription — peek-then-upsert verified safe (unique_index); on_conflict shape → NEEDS-REVIEW
- [x] check_limit
- [x] start_checkout
- [x] open_billing_portal
- [x] ensure_paddle_customer — orphan race already in NEEDS-REVIEW
- [x] record_and_apply_event — Repo.transaction → Multi
- [x] apply_webhook_event
- [x] extract_next_billed_at
- [x] billing_summary
- [x] subject_can_manage_billing?
- [x] headroom

### F9. Policies

- [x] default_rules
- [x] risk_tiers
- [x] decisions
- [x] decision_rank
- [x] change_policy
- [x] fetch_policy
- [x] save_rules
- [x] update_rules
- [x] subject_can_manage_policies?
- [x] seed_policy
- [x] peek_policy_for_account
- [x] evaluate
- [x] evaluate_with_policy
- [x] diff_rules
- [x] (F9 walked CLEAN — no findings; create_first_policy race-safe, update_rules uses builder, atomize is whitelist)

### F10. Runbooks

- [x] list_runbooks
- [x] fetch_runbook_by_id
- [x] change_runbook
- [x] create_runbook
- [x] save_new_version
- [x] publish
- [x] expand
- [x] dispatch_runbook
- [x] dispatch_next_step (actual: dispatch_next_batch)
- [x] subject_can_manage_runbooks?
- [x] (only finding: log_wave_dispatch_failure R18 → Audit.Events.runbook_step_dispatch_failed)

### F11. ApiKeys

- [x] list_api_keys_for_account
- [x] list_audit_export_keys_for_account
- [x] fetch_api_key_by_id
- [x] change_key
- [x] create_key
- [x] mint_quick_key
- [x] revoke_api_key
- [x] peek_api_key_by_secret
- [x] create_backing_key
- [x] peek_api_key_by_id
- [x] record_client_info
- [x] subject_can_manage_api_keys?
- [x] (F11 walked CLEAN — no findings; all audits already use builders, Multi/fetch_and_update throughout)

### F12. OAuth

- [x] register_client
- [x] fetch_client
- [x] issue_code — IL-3: Subject was first → now last; consent-audit gap → NEEDS-REVIEW
- [x] exchange_code
- [x] refresh
- [x] resolve_access_token
- [x] supported_scopes

### F13. Audit

- [x] put_request_metadata
- [x] get_request_metadata
- [x] clear_request_metadata
- [x] log
- [x] changeset
- [x] log_for_user
- [x] user_changeset
- [x] run_event_changeset
- [x] list_events
- [x] list_for_export
- [x] max_export_limit
- [x] default_export_limit
- [x] fetch_event_by_id
- [x] resolve_references
- [x] (F13 walked CLEAN — audit infra itself; normalize uses to_existing_atom, resolve_references is the sanctioned cross-context label resolver)

## H. Full-codebase review (2026-06-12)

Bugs / smells / security / CLAUDE.md sweep over the Elixir portal + both
Go modules. Method: full mechanical battery (credo 0, compile -W, format,
485+537 tests, sobelow clean, hex.audit no retired pkgs, go vet/staticcheck/
govulncheck) + four read-only review agents, every concrete finding then
adversarially verified. **The codebase came back essentially clean** — the
two items below were this review's only *new* actionable findings, both
already fixed. Everything under "re-confirmed backlog" was already known
(memory: runner-security-audit-backlog / root AUDIT.md) and is restated
here only so the open set lives in one place.

### Fixed this pass (commit 92a6d4c — Go tests only)

- [x] **H1. `runner/pkg/actionspec/action_test.go` — dead `ptrDur` helper**
  (staticcheck U1000, never called). Removed.
- [x] **H2. `mcp/main_test.go` — `newSessionID() == newSessionID()` tautology**
  (staticcheck SA4000). False positive — the nonce makes the two calls
  differ — but the syntax tripped the linter; bound to two vars so the
  randomness check reads honestly. Intent unchanged. Both Go modules now
  staticcheck-clean except the SA1019 websocket deprecation (H7).

### Verified FALSE / no action (recorded so they're not re-chased)

- A review agent claimed `engine.go:607 combinedRedactor` "silently falls
  back and leaks the secret" on a bad pack regex. **False positive** —
  `RedactionRule.Validate()` (`actionspec/action.go:309`) compiles every
  regex at pack-load with a comment describing exactly this fail-open and
  why it fails closed early; the engine fallback is unreachable.
- A claimed "HIGH test goroutine leak hangs `-race`" — contradicted by the
  `internal/cloud` suite passing under `-race` (~30s).
- Portal correctness agent's 4 findings all resolved to documented-graceful
  behavior or guarded idempotent paths (runbook mid-exec runner deletion =
  graceful skip; deny double-cancel = `Runs.transition` idempotent guard;
  approval-email pagination = best-effort fan-out, dashboard badge backstops;
  idempotency-replay semantics = correct).

### Re-confirmed backlog — DONE 2026-06-12 (H3–H8, each its own commit)

Gated per commit: gofmt / go vet / staticcheck / go test (`-race` where it
matters). Both Go modules now staticcheck-clean (0 findings).

- [x] **H3. mcp cleartext-URL guard.** `checkEndpointScheme` refuses an
  `http://` `EMISAR_URL` to a non-loopback host at startup (https always
  fine; http only to localhost/127/::1, or `EMISAR_ALLOW_INSECURE=1`);
  non-http(s) schemes rejected. Table test. *(4586b59)*
- [x] **H4. runner string `max_length` validator.** Opt-in
  `validation.max_length` (bytes) on string/path/string_array; authoring-
  time rejection on wrong type + non-positive cap; runtime enforce per-value
  and per-array-element; showcase pack demo. *(c58cd14)*
- [x] **H5. runner token-file read hardened.** `O_NOFOLLOW` refuses a
  symlinked `token_path`; non-0600 perms rejected → re-register rewrites a
  fresh 0600 file. Test covers ok/loose/symlink. *(668dfd3)*
- [x] **H6. mcp idempotency keys off the decoded envelope id.** Replaced the
  first-`"id"` byte-scan with a `json.RawMessage` decode of only the top-
  level `id` — correct regardless of key order/nesting; payload still relayed
  verbatim. Regression test for nested-id / "id"-valued param / malformed
  frame. *(3ffa0db)*
- [x] **H7. `nhooyr.io/websocket` → `github.com/coder/websocket` v1.8.14.**
  Byte-identical API, import-path swap + `go mod tidy`; clears all SA1019.
  Full runner suite green `-race`. *(fa1c50e)* Bonus: removed the now-
  surfaced dead `outboundMsg` type alias → runner fully staticcheck-clean.
  *(ab25898)*
- [x] **H8. audit journal fsync.** `JSONLSink.Write` now `fsync`s before
  advancing the hash chain; a failed Sync is treated like a failed Write
  (chain head holds, next attempt re-chains). *(2b63428)*

### Accepted risk — no fix available

- [ ] **H9. `cowlib` advisory GHSA-g2wm-735q-3f56** (low; cookie-encoder
  injection). Enters ONLY via `telemetry_metrics_prometheus → plug_cowboy →
  cowboy` serving the internal `:9091/metrics` page (no cookies); the public
  app is **Bandit** (no cowlib). No patched cowlib published yet → nothing to
  bump to. Recheck on a cowlib fix release, or drop the dep if the Prometheus
  exporter ever moves off cowboy. `mix deps.audit` will keep flagging it
  meanwhile.


---

## NEEDS-REVIEW.md — all findings resolved

# Needs review — deferred findings from the NIGHT_TASKS sweeps

Items found by a G-sweep that are real but too risky/large to fix blind;
each needs a design call (or explicit user sign-off) before changing.

## ~~F12 — OAuth consent → execute-capable token is unaudited~~ RESOLVED

Fixed: `issue_code/3` now inserts `Audit.Events.oauth_consent_granted/3`
in the same Multi as the backing key + code (event registered in the
audit filter lists; covered by an oauth_test assertion). Token
exchange/refresh stays deliberately unaudited — per-hour noise; the
standing capability (the consent) is what operators review.

<details><summary>original finding</summary>

## F12 — OAuth consent → execute-capable token is unaudited

When an operator approves an OAuth client (`OAuth.issue_code/3`), it mints
a backing `api_key` with `actions:read` + `actions:execute` and an auth
code — but writes **no audit row**. `create_backing_key/4` is a plain
insert (unlike `create_key/2`, which audits `api_key.created`), and the
`api_key.bound` event only fires from `peek_api_key_by_secret/1` (static
bearer first-use), which the OAuth path never hits (it resolves via
`peek_api_key_by_id/1`). So "operator X granted Claude.ai execute access
to the fleet" leaves no trace — a real observability gap for a security
product. `issue_code/3` already holds the consenting `%Subject{}` + the
client + the minted key, so a `Multi.insert(:audit, …)` step with a new
`Audit.Events.oauth_consent_granted/3` builder is the natural fix —
deferred only because the event name/payload (and whether to also audit
token refresh) is a product decision + needs its own test.

</details>

## ~~F8 — `upsert_subscription` peek-then-insert/update~~ RESOLVED (kept, documented)

Decision: keep the shape. Webhook payloads carry PARTIAL attr sets, so a
replace-set `on_conflict` upsert would null fields the event didn't
mention; the unique index + Paddle redelivery already make the race
self-healing. The rationale now lives as a why-comment on
`upsert_subscription/2`.

<details><summary>original finding</summary>

## F8 — `upsert_subscription` is a peek-then-insert/update (style call)

`Billing.upsert_subscription/2` reads (`peek_subscription_for_account`)
then inserts-or-updates — the read-before-write shape CLAUDE.md steers
away from. It is **safe in practice**: there's a
`unique_index(:subscriptions, [:account_id])` + `unique_constraint`, so a
concurrent first-insert race hits the index → the loser's webhook
redelivers and takes the update branch; and Ecto's changeset update only
writes changed fields, so concurrent updates to different fields don't
clobber. The strict shape is a single `Repo.insert(cs, on_conflict:
{:replace, …}, conflict_target: :account_id)` true-upsert, but the
replace-set differs across `subscription.created` vs `.updated` payloads
(partial attrs), so it's a deliberate design call, not a blind swap. Low
severity — flagging rather than changing.

</details>

## ~~F1 redo — invitation tokens are stored raw at rest~~ RESOLVED

Fixed: invitations now follow the mint→hash contract.
`Crypto.user_invite_token/0` returns `{raw, digest}`; only the digest is
at rest (column renamed `invitation_token_digest`);
`fetch_invitation_by_token/1` re-hashes the presented raw via
`Crypto.user_invite_token_digest/1`. Invitations also lapse after 7 days
(`Membership.Query.invitation_not_expired/1`, keyed off `inserted_at` —
the invite time, since re-invites insert fresh rows). A corrective
migration (prod already ran the original) hashes existing stored tokens
in place via pgcrypto so pending invite emails keep working, then
renames the column. Tests cover digest-at-rest + expiry.

<details><summary>original finding</summary>

## F1 redo — invitation tokens are stored raw at rest

`memberships.invitation_token` persists the RAW invite secret
(`invite_user_to_account` stores what `Crypto.user_invite_token/0`
minted; `fetch_invitation_by_token/1` matches it by equality). Every
other bearer credential follows Crypto's mint→hash contract — a DB leak
exposes live invite links (claimable seats) until accepted. Fix shape:
store `hash(token)`, look up by hash, keep the raw only in the emailed
URL; needs a migration + invite/accept flow touch, and pending
invitations at migration time must be regenerated or backfilled. Also
worth adding an expiry — invitation tokens currently never lapse.

</details>

## ~~F1 redo — concurrent first-checkouts can orphan a Paddle customer~~ RESOLVED

Fixed (the "claim first-wins" option):
`Accounts.put_account_paddle_customer_id/2` is now a locked
`fetch_and_update` that keeps an already-linked customer id (empty
changeset no-op) instead of clobbering it, and
`Billing.ensure_paddle_customer/2` returns the id off the RETURNED row —
so the row write is first-wins and both racers converge on one customer.
The loser's vendor customer stays orphaned at Paddle by design (it bills
nothing); documented at both call sites.

<details><summary>original finding</summary>

## F1 redo — concurrent first-checkouts can orphan a Paddle customer

`Billing.ensure_paddle_customer/2` checks `paddle_customer_id` on the
caller's (stale) account struct before creating the vendor customer, so
two concurrent first-checkouts both create a Paddle customer and the
loser's is orphaned (the row keeps one id; no double-charging). A row
lock can't fix it cleanly — the vendor HTTP call would have to happen
under the lock. Options: accept the harmless orphan (likely), or claim
via `fetch_and_update` + `filter: is_nil(paddle_customer_id)` so at
least the row write is first-wins. Low severity, money-adjacent, so
flagging for a deliberate call.

</details>

## ~~G12 — OAuth uses imperative transactions~~ RESOLVED

Fixed in the F12 pass (`cc479a0`): issue_code / exchange_code / refresh
are Multis; refresh rotation now locks the token row.
(`catalog.ex`'s `Repo.transaction(fn)` in `observe_state` remains the
documented per-row error-isolation exception.)

## ~~G4 — run state transitions update a possibly-stale struct~~ RESOLVED

Fixed in the F5 pass (`dad8533`): `transition/3` re-reads the row
`FOR NO KEY UPDATE` inside its Multi and treats already-terminal as a
benign no-op; a regression test pins the stale-struct race.

## ~~G8 — fixed string-set fields still `:string` + `validate_inclusion`~~ RESOLVED

Fixed (`04c111f`): seven owned state machines are Ecto.Enums
(ActionRun status/source, Request status, Runbook status,
PackVersion trust_state, RunnerAction risk/kind, RunEvent kind). Two
stay strings BY DESIGN with why-comments at the field:
Subscription.status (Paddle owns the value space — unseen vendor
statuses must persist, not 500 the webhook) and Account.plan (writes
stay inclusion-constrained, but stored legacy/renamed plan names must
still LOAD and degrade to free-tier limits — an enum raises on fetch).

## ~~F1 — `count_owners` last-owner guard is a TOCTOU~~ RESOLVED

Fixed (`316d17c`): the guard is a shared Multi step that locks the
account's active owner rows `FOR NO KEY UPDATE` and re-counts inside
the transaction across all three call sites; `count_owners/1` and the
pre-checks are deleted.

(`update_account` initially stayed on the stale-changeset shape so the
field-aware permission check covered the written diff; it has since
moved to `fetch_and_update` with the escalation check INSIDE `:with`,
judged on the fresh diff under the row lock — strictly stronger.)

## ~~G4 — runner enable/disable/delete update the fetched struct~~ RESOLVED

Fixed in the F4 pass (`f03df33`): disable/enable/delete_runner and
revoke_auth_key now go through `Repo.fetch_and_update/3` with
`for_subject` row scoping.
