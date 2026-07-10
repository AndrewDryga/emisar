# Reviewer tenant — provisioning runbook

A disposable emisar account a catalog reviewer (Anthropic, OpenAI, Cursor, or the
MCP Registry) can sign into and drive end-to-end **without touching any real
infrastructure**. It demonstrates the whole product loop — a read-only action that
runs, a risky one that pauses for approval, and one that is denied — against a
sandbox runner whose action catalog authenticates to nothing.

This is an **operator runbook**: every step here needs live product access, a real
host for the sandbox runner, a browser, and the ops secret store. None of it is
done from the repo or CI, and none of it is a blocked decision — it is execution.
Nothing in this file is a secret; credentials live only in the `emisar-ops`
1Password vault.

## Safety guarantees (why this touches nothing real)

- The sandbox runner runs the **`showcase` pack only** — a synthetic reference pack
  whose every action runs a trivial local `echo`/bundled script and authenticates
  to nothing (no env vars, no credentials). It is explicitly "not a production
  pack."
- The runner host is a throwaway VM with no cloud credentials, no SSH keys to real
  fleets, and no network path to production.
- The reviewer account has **no** billing, **no** real runners, and **no**
  membership in any real account.

## 1. Disposable reviewer account

1. Create a fresh account (e.g. slug `catalog-review`) with a role-inbox email you
   control (e.g. `reviewer@emisar.dev` or a `+catalog` alias). One owner member.
2. **Do not enroll MFA** and do not require SSO — a reviewer must sign in with just
   the emailed magic link / password, no second factor and no interactive identity
   verification. (emisar seeds never fake a second factor; keep this account in the
   same shape — a real, MFA-free login.)
3. Note the sign-in method the reviewer will use in the credential entry (§7).

## 2. Sandbox runner

1. Provision a throwaway VM (any cheap cloud instance or local container) with **no
   access to real infrastructure** — no cloud creds, no fleet SSH keys.
2. Install the runner and register it to the reviewer account (name it `demo`).
3. Confirm it shows **connected** in the dashboard and advertises only the showcase
   actions once the pack is installed (next step).

## 3. Install & trust the showcase pack

1. Install the `showcase` pack on the `demo` runner.
2. On the **Packs** page, **trust** the installed pack version (an untrusted pack
   yields `pack_untrusted` at dispatch — trusting it is the operator gate).
3. Verify `tools/list` now shows the 5 showcase action tools + 6 synthetic tools
   (11 total) — see `mcp-catalog-submission.md` §9 for the capture command.

## 4. Demo policy — allow / approve / deny

The showcase actions are all `risk: low`, so the three outcomes are produced with
**per-action overrides** on the account policy (edit on the **Policies** page):

| Action | Outcome | How |
|---|---|---|
| `showcase.path_validation` (read-only file inspection) | **allow** — runs immediately | tier default `low = allow`, no override |
| `showcase.script_action` (packaged script) | **require_approval** — pauses for a human | per-action override `require_approval` |
| `showcase.every_arg_type` | **deny** — refused | per-action override `deny` |

Policy model (for reference): tier defaults map `low`/`medium`/`high`/`critical` →
`allow`/`require_approval`/`deny` and must be monotonic (a higher tier can't be
more permissive than a lower one); per-action overrides pin a specific `action_id`
to a decision regardless of its tier. Set the account default to `low = allow`
(so the read-only demo runs), then add the two overrides above. Leave
single-approver approval (default) so one operator can approve G2.

## 5. Reviewer MCP credential

- **For an OAuth reviewer (Claude.ai / ChatGPT):** nothing to pre-mint — the
  reviewer pastes `https://emisar.dev/api/mcp/rpc`, signs into this account, and
  authorizes. The consent screen mints a key bound to the reviewer's membership.
- **For a key-based reviewer (Cursor local / CLI / the §9 capture command):** mint
  an `emk-` MCP key on the **LLM agents** page under the reviewer member (whose
  runner scope is just the `demo` runner). Reveal-once — copy it straight into the
  ops vault. This is the `EMISAR_REVIEWER_KEY` referenced by the tool-inventory
  capture.

## 6. Populate run history

Drive the three flows once (from the connected client, or via the REST/JSON-RPC
endpoint with the reviewer key) so the reviewer lands on a non-empty audit trail:

1. **Allow:** dispatch `showcase.path_validation` with a `reason` → completes;
   output visible.
2. **Approve:** dispatch `showcase.script_action` with a `reason` → `pending_approval`
   → approve it in the dashboard → run completes.
3. **Deny:** dispatch `showcase.every_arg_type` with a `reason` → policy denial.

Confirm the **Audit** page shows all three, each attributed to the reviewer (human
name, with the key/client as `via` context) and carrying its `reason`. Capture the
screenshots listed in `mcp-catalog-submission.md` §3.

## 7. Credentials: storage, rotation, deletion

- **Store** in the `emisar-ops` 1Password vault, item `catalog-reviewer-tenant`:
  the account slug, the reviewer login email + sign-in method, and (if minted) the
  `emk-` key. **Never** commit any of these, and never paste a key into a vendor
  form — deliver it over the secure channel each vendor specifies.
- **Rotate** the `emk-` key from the LLM agents page (revoke + re-mint) after each
  review round, or immediately if a key was shared in a review thread; update the
  vault item. OAuth grants are revoked from **LLM agents** in the dashboard (or by
  the reviewer in their client).
- **Delete** when the review is closed: revoke all keys/grants, delete the reviewer
  account (or suspend it), tear down the sandbox VM, and archive the vault item.
  Leaving a dormant MFA-free account and a live key around is the abuse surface —
  close it out.

## What stays human-owned

Everything above (live account, live runner host, browser-driven flows, vault
access) is operator-run and cannot be produced from the repo. This file is the
durable procedure so any operator can stand the tenant up, capture the evidence,
and tear it down the same way each time.
