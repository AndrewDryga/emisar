# Emisar UI, UX, and Content Audit

Audit date: 2026-07-16

Audited revision: `0540f1fb` on `main`, local release `0.30.0`

Verdict: **Not ready to ship without fixes.** The billing-manager authorization path is a release blocker. Seven high-severity issues follow it, including a false payment-success message, a pricing/entitlement contradiction, systemic accessibility failures, mobile overflow on every pack detail page, and stale runner-enrollment documentation.

## Evidence and method

The audit produced **1,186 current-state screenshots**. The route/state manifests and images are stored with Coop task `2026-07-16-audit-every-marketing-and-portal-page-with-scree` under `portal/.agent/tasks/99_done/`.

Coverage:

- 369 public captures: 123 routes at `1440x1000`, `1024x768`, and `390x844`. This includes every current pack detail page (80), every current guide, and missing guide/pack cases.
- 306 owner captures: 102 product routes and records at all three widths, including valid, missing, and cross-account detail URLs.
- 182 multi-account state captures: blank Free, populated Free, populated Team, and connected-with-no-runs accounts at desktop and mobile widths.
- 260 role captures: real invited owner, admin, operator, viewer, and billing-manager users across 26 routes at desktop and mobile widths.
- 35 critical-flow screenshots and 37 recorded checkpoints: signup, runner enrollment-key reveal, dispatch, approval, denial, policy denial, runbook and policy validation, every supported LLM client, invitation handling, and OAuth consent.
- 25 signed-out/auth state captures and 9 MFA lifecycle captures.
- Axe WCAG 2 A/AA, 2.1 A/AA, and 2.2 AA checks on 675 public/owner captures; browser console, failed-response, overflow, title, metadata, headings, and asset checks were also recorded.
- The full local Keycloak SSO/SCIM E2E suite passed: SCIM provision/read/deprovision and OIDC discovery/login/callback.

Primary manifests:

- `public-audit.json`
- `privacy-current-audit.json`
- `portal-owner-audit.json`
- `account-states-audit.json`
- `roles-audit.json`
- `critical-audit.json`
- `auth-states-audit.json`
- `mfa-modal-probe.json`

Screenshot paths below are relative to the task directory.

## Findings

### P0 - Release blocker

#### UI-001: Billing-manager authorization fails as load errors, crashes detail pages, and exposes policy configuration

- **Routes/states:** Direct URLs as a real `billing_manager`: `/app/demo/runners`, `/runs`, `/approvals`, `/audit`, `/settings/team`, `/runners/:id`, `/runs/:id`, `/approvals/:id`, and `/policies`; desktop and mobile.
- **Evidence:** The role contract says this finance-only seat has "no team, runner, policy, or action access" (`Auth.Role`, lines 44-45; Teams docs, lines 56-61). Index pages render misleading "Couldn't load" recovery panels. Team stays on `Loading...` while LiveView reconnects. Runner, run, and approval details return HTTP 500. Policy renders the default decisions, self-approval posture, approval count, and per-action overrides before only the targeted-ruleset read fails.
- **Source:** Detail LiveViews handle `:not_found` but not `:unauthorized` (`runner_detail_live.ex:10`, `run_detail_live.ex:21`, `approval_detail_live.ex:22`). Team also pattern-matches an authorized runner list at `team_live.ex:570`. Server logs show `CaseClauseError`/`MatchError` on `{:error, :unauthorized}`.
- **Screenshots:** `screenshots/roles/billing_manager--desktop--app--demo--policies.jpg`, `screenshots/roles/billing_manager--desktop--app--demo--settings--team.jpg`, `screenshots/roles/billing_manager--desktop--app--demo--runners--019f68c2-964c-7496-80a2-a01b3d004ee8.jpg`, `screenshots/roles/billing_manager--desktop--app--demo--runs--019f6d93-ea09-7a60-9e00-4e3b14f36db0.jpg`, `screenshots/roles/billing_manager--desktop--app--demo--approvals--019f68c2-9859-7c43-8632-2ba502bee8d4.jpg`.
- **Impact:** A deliberately narrow finance seat can learn security policy posture and can turn direct or stale URLs into server errors. The UI also teaches the user that authorization failures are transient infrastructure failures.
- **Fix:** Gate these routes before mount, return one consistent permission-denied/404 outcome, handle every context error tuple, and make the policy authorizer match the documented role contract. Add direct-URL tests for every role, not only navigation visibility tests.

### P1 - High

#### UI-002: The checkout success URL claims payment without verifying a transaction

- **Route/state:** Authenticated `GET /app/checkout/success` with no query string or transaction.
- **Evidence:** It redirects to Billing with "Payment received - your subscription updates in a few seconds." `CheckoutController.success/2` ignores all params and always emits the success flash (`checkout_controller.ex:37-42`).
- **Screenshot:** `screenshots/portal-owner/desktop--app--checkout--success.jpg`.
- **Impact:** An operator can be told money was received when no checkout happened. This is a material trust failure on a billing surface.
- **Fix:** Require a signed/provider transaction reference, resolve it server-side to the current account, and use a neutral "verifying payment" state until the webhook-backed subscription is present. Invalid or missing references must not claim success.

#### UI-003: Free advertises and measures one user but the product allows unlimited invitations

- **Routes/states:** `/pricing`, Free `/settings/billing`, Free `/settings/team`, and `/settings/team/invite`.
- **Evidence:** Pricing and Billing say `1 user` and show `Team members 1 / 1`, yet the invite form remains available and a Free account successfully creates another membership. The context explicitly says Free's member limit is "aspirational, not gates" (`accounts.ex:1461-1464`).
- **Screenshots:** `screenshots/public/desktop--pricing.jpg`, `screenshots/account-states/blank-free-empty--desktop--app--blank--settings--billing.jpg`, `screenshots/account-states/blank-free-empty--desktop--app--blank--settings--team--invite.jpg`.
- **Impact:** The offer, usage meter, and behavior describe three different products. Buyers cannot know whether collaboration requires Team, and the usage bar falsely looks exhausted.
- **Fix:** Make a product decision and align all three layers. Either enforce one member on Free with a clear upgrade path, or advertise unlimited members and remove the false limit/meter.

#### UI-004: Low contrast is systemic across the public site and portal

- **Routes/states:** 369/369 public captures and 300/306 owner captures at all widths.
- **Evidence:** Axe reported at least 10,647 failing nodes (results retain a maximum of 20 nodes per rule/page): 6,350 public and 4,297 portal. Repeated offenders are `text-zinc-500`/`text-zinc-600` on black or near-black, including navigation, captions, metadata, legal copy, auth guidance, timestamps, and disabled-looking text that is still essential.
- **Screenshots:** Representative: `screenshots/public/desktop--home.jpg`, `screenshots/public/mobile--privacy.jpg`, `screenshots/portal-owner/desktop--app--demo.jpg`.
- **Impact:** Important product and legal information does not meet normal-text contrast requirements; the problem is a token/system issue, not isolated copy.
- **Fix:** Raise the base muted-text tokens to AA contrast, reserve lower contrast for genuinely nonessential decoration, and add automated rendered contrast coverage for the shared marketing and console shells.

#### UI-005: Signup and policy approval-count controls have no programmatic labels

- **Routes/states:** `/sign_up` and `/app/demo/policies`, all three widths.
- **Evidence:** Axe flags `input[name="account_name"]` and `input[name="policy[approval][min_approvals]"]` at every width. Signup visually renders "Team or company name", but the input is created without an ID association; Playwright could not locate it by label. The approval-count input has no accessible name at all.
- **Screenshots:** `screenshots/public/desktop--sign_up.jpg`, `screenshots/portal-owner/desktop--app--demo--policies.jpg`.
- **Impact:** Screen-reader and voice-control users cannot identify two consequential inputs, including one that changes independent approval requirements.
- **Fix:** Give both controls stable IDs and real `<label for>` associations. Include the approval requirement in the accessible name, not only surrounding prose.

#### UI-006: Keyboard users cannot operate many horizontally scrollable code/output regions

- **Routes/states:** 104 public captures (147 nodes) and 27 owner captures (29 nodes).
- **Evidence:** Axe `scrollable-region-focusable` failures cover code examples, install commands, schemas, run output, and other overflow containers. The content can be clipped without a keyboard-scroll target.
- **Screenshots:** Representative: `screenshots/public/mobile--docs--mcp-reference.jpg`, `screenshots/portal-owner/mobile--app--demo--runs--019f6d93-ea09-7a60-9e00-4e3b14f36db0.jpg`.
- **Impact:** Keyboard-only users can miss command/output content or cannot inspect it horizontally.
- **Fix:** Make each intentional scroll region focusable, give it an accessible label where context is not obvious, and show a visible focus state. Prefer wrapping where code semantics permit.

#### UI-007: Every public pack detail page overflows the mobile viewport

- **Routes/states:** All 80 `/packs/:id` pages at `390x844`.
- **Evidence:** Every mobile pack detail expands the document from 390px to 494px. The unbroken content hash at `pack_detail.html.heex:103-105` measures 470px inside a 342px content width; install code is separately scrollable.
- **Screenshot:** `screenshots/public/mobile--packs--clickhouse.jpg` (representative; the manifest records all 80).
- **Impact:** The entire page can pan sideways, destabilizing reading and making controls appear off-screen on a core acquisition/catalog surface.
- **Fix:** Constrain the hash row with `min-w-0` and `overflow-wrap:anywhere`/a deliberate copyable truncation pattern. Keep only code blocks locally scrollable and add a regression test using a real SHA-256 value.

#### UI-008: Runner enrollment documentation contradicts the current reusable-key product

- **Routes/states:** `/docs/runners` versus `/app/:account/runners/keys/new`.
- **Evidence:** Docs say every key is "Single-use, shown once" and "enrolls exactly one runner" (`docs_runners.html.heex:45-51`). The product now supports reusable keys and optional maximum-use limits, and its form explains both models.
- **Screenshots:** `screenshots/public/desktop--docs--runners.jpg`, `screenshots/portal-owner/desktop--app--demo--runners--keys--new.jpg`.
- **Impact:** Fleet operators may mint and distribute keys under the wrong security/rotation assumptions. This is operational documentation for a trust boundary, not harmless marketing drift.
- **Fix:** Document single-use and reusable keys separately, state when each is appropriate, explain maximum uses and revocation, and update the provisioning guidance that currently mandates one key per host.

### P2 - Moderate

#### UI-009: A non-SSO account can render a false "SSO required" interstitial

- **Route/state:** Direct `GET /app/demo/sso_required` while signed in normally to an account that does not require SSO.
- **Evidence:** The page states that the team requires SSO and asks the user to end the session. `SSORequiredController.show/2` renders unconditionally (`sso_required_controller.ex:13-16`).
- **Screenshot:** `screenshots/portal-owner/desktop--app--demo--sso_required.jpg`.
- **Impact:** A stale, copied, or malicious link can present a false security state and persuade an operator to sign out.
- **Fix:** Re-check account compliance on GET and redirect compliant sessions to the dashboard. Render the interstitial only for an active, noncompliant SSO requirement.

#### UI-010: SSO documentation sends operators to a page that no longer exists as described

- **Route/state:** `/docs/sso`; actual `/app/:account/settings/sso` behavior.
- **Evidence:** The docs twice instruct "Settings -> Single sign-on" and say screenshots show that page (`docs_sso.html.heex:22-24,44-47`). The current console places SSO inside Team; `/settings/sso` redirects to `/settings/team` without deep-linking the SSO section.
- **Screenshots:** `screenshots/public/desktop--docs--sso.jpg`, `screenshots/portal-owner/desktop--app--demo--settings--team.jpg`.
- **Impact:** Admins following a security setup runbook land at the top of a large Team page and must rediscover the feature.
- **Fix:** Update all directions and screenshots to "Team -> Single sign-on" and deep-link/anchor the redirect to the SSO section.

#### UI-011: Privacy says name is optional while signup requires it

- **Routes/states:** `/privacy` and `/sign_up`.
- **Evidence:** Privacy states "your name (optional)" (`privacy.html.heex:22`); signup marks "Your name" required (`user_sign_up_live.ex:40`) and rejects omission.
- **Screenshots:** `screenshots/public/desktop--privacy.jpg`, `screenshots/public/desktop--sign_up.jpg`.
- **Impact:** The legal disclosure does not match collection behavior.
- **Fix:** Either make signup name optional end to end or remove "optional" from the privacy notice. Confirm the retention/deletion text uses the same definition of profile data.

#### UI-012: Persistent demo billing data shows paid invoices and subscription management on a Free account

- **Route/state:** Blank Free account `/app/blank/settings/billing` after repeated seed/audit runs.
- **Evidence:** The page simultaneously shows `Free`, `$0/mo`, `Manage subscription`, and three `$20.00` invoices. Current seeds say only the Team account receives a Paddle customer (`seeds.exs:1764-1771`), so persistent local rows can retain stale billing linkage across reseeds.
- **Screenshot:** `screenshots/account-states/blank-free-empty--desktop--app--blank--settings--billing.jpg`.
- **Impact:** The demo/E2E environment cannot reliably validate billing-state UX or account isolation; screenshots can normalize impossible customer states.
- **Fix:** Make reseeding reconcile/remove stale Paddle IDs and subscriptions for deterministic personas, or reset the audit DB. Add fixture assertions for Free-without-customer and per-account invoice isolation.

#### UI-013: The mobile Runs page is a 7,011px wall of repeated field labels

- **Route/state:** Populated `/app/demo/runs` at 390px.
- **Evidence:** Roughly 35 rows repeat `WHEN / ACTION / RUNNER / STATUS / DURATION` plus actor metadata, producing more than eight mobile viewports with weak comparison rhythm.
- **Screenshot:** `screenshots/portal-owner/mobile--app--demo--runs.jpg` (`390x7011`).
- **Impact:** Operators cannot quickly compare status, recency, or action across many runs, which is the page's primary job.
- **Fix:** Use a compact two-line mobile row with status and action as the dominant scan line, subordinate runner/time metadata, and pagination or progressive loading. Do not repeat five uppercase labels per row.

#### UI-014: Runner detail makes large action catalogs effectively undiscoverable

- **Route/state:** `/app/demo/runners/:id` for runners advertising 58-82 actions, especially mobile.
- **Evidence:** The page places 20 recent runs before a paged action list and offers no action search, pack filter, risk filter, or jump link. One representative mobile page is `390x6253`.
- **Screenshot:** `screenshots/portal-owner/mobile--app--demo--runners--019f68c2-964c-7496-80a2-a01b3d004ee8.jpg`.
- **Impact:** Starting a known action requires extensive scrolling and page-by-page scanning on the very page intended to expose a runner's capabilities.
- **Fix:** Add action search/filtering and a stable section jump; collapse recent runs on mobile or put actions first when the operator arrives through a dispatch path.

#### UI-015: Profile renders up to 100 active sessions as an ungrouped wall

- **Route/state:** `/app/:account/settings/profile` after repeated magic-link/MFA sign-ins.
- **Evidence:** The critical-state capture contains 78 indistinguishable "Chrome on Mac" rows and is `1440x6832`. `ProfileLive` requests a fixed `limit: 100` (`profile_live.ex:46`) with no pagination, grouping, or older-session summary.
- **Screenshot:** `screenshots/critical/mfa-invalid-totp.jpg`.
- **Impact:** The security task - identifying and revoking an unfamiliar session - becomes slower as the account is used, while nearly identical automation/browser sessions drown the current one.
- **Fix:** Group or summarize by device/IP, expose last activity, paginate or initially cap the list, and retain "sign out everywhere else" as the fast recovery action.

#### UI-016: Shared confirmation dialogs lose focus when closed with Escape

- **Routes/states:** Profile `Disable 2FA` and all actions using the shared plain `confirm_button`.
- **Evidence:** Opening the dialog focuses Cancel correctly. Escape hides it, but `document.activeElement` becomes the document body instead of the original trigger (`mfa-modal-probe.json`). The disable flow itself succeeds with a valid recovery code.
- **Screenshot:** `screenshots/mfa/mfa-disable-modal-open.jpg`.
- **Impact:** Keyboard and screen-reader users lose their position after canceling destructive actions; the defect is shared across runner, team, session, MFA, and other confirmation surfaces.
- **Fix:** Capture the opener and restore focus after Escape, backdrop, and Cancel. Add a browser-level component test for open focus, focus containment, Escape, and return focus.

#### UI-017: Routine runner connection events overwhelm the Audit page's decision trail

- **Route/state:** Populated `/app/demo/audit`, especially mobile.
- **Evidence:** Repeated runner-connected/disconnected lifecycle events dominate the first page before action, approval, access, and policy decisions. Quick filters offer time and "Problems only", but not the primary security categories.
- **Screenshot:** `screenshots/portal-owner/mobile--app--demo--audit.jpg` (`390x2674`).
- **Impact:** The append-only record exists, but the default view makes consequential human/agent decisions harder to locate during review or incident response.
- **Fix:** Add event-category quick filters and consider a default/security-review preset that groups or de-emphasizes connection churn without removing it from the record.

#### UI-018: Public and auth positioning is approval-centric and uses stale product terminology

- **Routes/states:** Home and desktop auth pages.
- **Evidence:** Auth leads with "Give AI tools approved infrastructure actions, not SSH" and "Pre-approved playbooks" while the product calls them runbooks. Home says "risky changes wait for one human" even though policy supports multiple distinct approvals and denial. The message underplays bounded autonomous work and overstates one fixed approval model.
- **Screenshots:** `screenshots/public/desktop--home.jpg`, `screenshots/auth-states/desktop--app--demo--sign_in.jpg`.
- **Impact:** The first impression describes an approval wrapper rather than the product's broader value: agents can safely keep working inside declared, enforced bounds. Security-capable buyers also receive an inaccurate approval claim.
- **Fix:** Lead with bounded autonomy; support it with declared actions, policy, approvals where needed, and audit. Use `runbooks` consistently and describe risky work as policy-gated rather than always waiting for exactly one human.

#### UI-019: Billing managers land on infrastructure onboarding they cannot perform

- **Route/state:** `/app/demo` as `billing_manager`.
- **Evidence:** The dashboard leads with "Get to your first gated run" and runner/agent setup guidance, while the role is finance-only and its navigation exposes only Team/Billing/resources.
- **Screenshot:** `screenshots/roles/billing_manager--desktop--app--demo.jpg`.
- **Impact:** The role's first screen is a dead-end tutorial for capabilities it intentionally lacks.
- **Fix:** Give finance-only users a billing posture landing state (plan, renewal/status, usage, invoices, payment actions) or redirect them directly to Billing.

#### UI-020: Body links are frequently distinguishable only by color

- **Routes/states:** 357/369 public captures (856 recorded nodes) plus three owner captures.
- **Evidence:** Axe `link-in-text-block` flags legal, documentation, support, and explanatory links whose only persistent distinction is color.
- **Screenshots:** Representative: `screenshots/public/desktop--privacy.jpg`, `screenshots/public/desktop--docs--security-model.jpg`.
- **Impact:** Low-vision and color-deficient users can miss links embedded in prose, including legal rights and operational documentation.
- **Fix:** Underline in-content links by default (with appropriate offset/thickness) or provide another non-color visual distinction; navigation and button-like links can retain their existing treatment.

### P3 - Minor

#### UI-021: The mobile home page is excessively long and repeats its proof/CTA rhythm

- **Route/state:** `/` at 390px.
- **Evidence:** The full page is `390x18207`, about 21.6 initial viewports. Multiple sections restate safety, control, workflow, and calls to start without enough new decision-making information.
- **Screenshot:** `screenshots/public/mobile--home.jpg`.
- **Impact:** The core offer and proof are diluted; mobile visitors must traverse a very long narrative to compare plans or act.
- **Fix:** Merge repetitive proof sections, retain one concrete end-to-end workflow and one trust/security proof band, and keep the primary CTA available after the decisive evidence.

#### UI-022: Invalid or consumed auth tokens use a generic "Something went wrong" heading

- **Routes/states:** Invalid/used `/accept_invitation/:token` and `/confirm/:token` states.
- **Evidence:** The body often explains the token problem, but the dominant toast/title is generic and sounds like an internal failure.
- **Screenshot:** `screenshots/auth-states/desktop--accept_invitation--not-a-real-token.jpg`.
- **Impact:** Users cannot immediately distinguish an unavailable invitation from a service failure and may retry or contact support unnecessarily.
- **Fix:** Use state-specific headings such as "Invitation unavailable", "Invitation already used", or "Confirmation link expired", with a direct recovery action.

## Critical flows that worked

- Registration validation, magic-link pending/wrong-code handling, and first dashboard entry.
- Runner enrollment-key reveal-once behavior; reloading does not reveal the secret again.
- Low-risk dispatch and high-risk dispatch approval/denial, including required-reason validation.
- Critical-risk action denial by the default policy.
- Runbook and policy validation errors remain inline and preserve context.
- Every supported LLM client tab renders its connection instructions; custom-key advanced controls render.
- OAuth consent approve and deny callbacks.
- MFA setup, recovery-code reveal, valid/invalid TOTP, valid/consumed recovery codes, and disablement.
- Owner/admin/operator/viewer navigation and direct cross-account/missing-record behavior were generally consistent; owner cross-account access returned 404.
- Local Keycloak SCIM and OIDC E2E completed successfully.

## Coverage limits and excluded artifacts

- No real Paddle sandbox credentials were available. Past-due, cancellation, provider-outage, and real checkout-overlay states were not executed against Paddle; local/stub UI and controller boundaries were audited instead.
- SAML is not a supported setup option, so only OIDC was exercised.
- Password-change coverage is not applicable because the product is passwordless.
- Unsubscribe tokens are signed and idempotent rather than database-backed single-use/expiring records; valid, invalid, and completed states were covered.
- A Packs LiveView crash observed in an older running `0.29.0` container was excluded after rebuilding. It is already fixed in the audited `0.30.0` source. Download-navigation `about:blank` title/lang warnings and full-page JPEG blank space beyond Chromium's rendering limit were also excluded as harness artifacts.
- A Privacy-page commit landed during the run; `/privacy` was rebuilt and recaptured at all three widths against `0540f1fb`. `privacy-current-audit.json` supersedes those three records in the broad public manifest.
- Manifests, not the raw directory file count, are the evidence index. The directory intentionally retains superseded and partial-run screenshots for traceability.

## Fix order

1. Fix UI-001 across the permission boundary and add the full direct-route role matrix.
2. Fix UI-002 and UI-003 before making billing/pricing claims public.
3. Correct the shared accessibility system: contrast, labels, scroll focus, dialog return focus, and in-text link treatment.
4. Fix pack mobile overflow and update the runner/SSO/privacy content contracts.
5. Improve high-volume operational scanning: Runs, runner actions, sessions, and Audit.
6. Refresh positioning and role-specific dashboard content, then tighten the home-page narrative and token error copy.
