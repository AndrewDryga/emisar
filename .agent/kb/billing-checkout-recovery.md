---
name: billing-checkout-recovery
description: one-shot checkout reservations, exact provider binding, durable duplicate-subscription cleanup, and account closure
subsystem: portal
sources: [portal/apps/emisar/lib/emisar/billing.ex, portal/apps/emisar/lib/emisar/billing/checkouts.ex, portal/apps/emisar/lib/emisar/billing/subscription_retirements.ex, portal/apps/emisar/lib/emisar/billing/jobs/sync_subscriptions.ex, portal/apps/emisar/lib/emisar/accounts.ex]
updated: 2026-09-16
---

Billing commits one current checkout intent per account before creating a
provider transaction. Only the fresh reservation winner submits that request.
An ambiguous result remains reserved; retries discover its transaction through
bounded provider pages instead of submitting another create. A reservation whose
clean discovery is still empty an hour after it was made is failed (`checkouts.ex`
`recover/1`), so the next attempt reserves fresh and account closure proceeds;
Paddle creates transactions synchronously, so nothing arrives later. A changed cadence,
price, or quantity waits for confirmed cancellation of the previous unpaid
transaction. A paid transaction waits for its subscription linkage.

The intent UUID correlates requests; the existing signed account/transaction
binding supplies authority. Customer identity alone does not authorize automatic
cancellation. Ordinary authenticated, unsigned subscription receipts still support
no-conflict adoption when the customer identifies exactly one account.

First-seen signed subscriptions are verified against current provider transaction
and subscription data before the short webhook transaction. Under account and
subscription locks, that transaction either adopts the candidate or commits its
retirement alongside receipt deduplication. A different live canonical subscription
is refreshed first; a replacement starts with clean provider fields and clocks.

The subscription sweep recovers pending intents before provider discovery and
pending retirements afterward. Confirmed retirement IDs remain recorded so delayed
events cannot adopt them. Both recovery tables contain opaque identities without
an account foreign key; cleanup continues after hard erasure. Cancellation leaves
the initial charge unchanged.

Account closure performs provider cleanup outside its final database transaction,
persists confirmed canonical cancellation with an optimistic mirror guard, then
checks all remaining work under the account lock before tombstoning. A failed
database write after provider cancellation is repaired by a subsequent GET.

First-rollout ordering is in [the checkout cutover runbook](runbooks/billing-checkout-cutover.md).

## Changelog

- 2026-09-16 — abandoned `creating` reservations fail after an hour; closure recovers them first.
- 2026-09-05 — documented durable checkout and retirement recovery and two-phase closure.
