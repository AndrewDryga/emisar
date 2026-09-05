# First durable-checkout rollout

This procedure applies when replacing checkout producers that predate durable
reservations. It does not authorize a deployment or a billing mutation.

1. Quiesce every previous-version checkout-producing instance and wait for its
   in-flight checkout requests to finish before enabling checkout traffic on the
   new version. An old producer cannot honor the new reservation table; overlapping
   versions would bypass its one-create boundary.
2. Apply the forward `20261025000000_track_checkout_and_subscription_recovery`
   migration through the normal release migration procedure. Historical migrations
   are unchanged. Start the new application and its existing subscription sweep.
3. Verify checkout traffic reaches only the new version. Exercise the normal
   authorized release checks; do not create a real paid checkout solely to probe
   the database boundary without separate permission.

Existing signed payment links do not expire. Before a fresh reservation, the new
code scans bounded full-history transaction pages and blocks if an earlier owned
checkout or payment remains unresolved. It does not import, rebind, or cancel old
unpaid links automatically. A failed or incomplete scan also blocks creation.

For an unresolved account, inspect its opaque checkout/retirement records and the
exact linked provider transaction and subscription. Preserve ambiguous creating
rows and confirmed retirement IDs: deleting them removes the safety evidence.
Resolve provider state through an explicitly authorized support workflow, then
retry reconciliation. Cancellation of a duplicate subscription stops recurrence;
it does not refund an initial payment.

See [billing checkout recovery](../billing-checkout-recovery.md) for ownership and
durability boundaries.
