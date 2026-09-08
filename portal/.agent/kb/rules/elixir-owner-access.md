# Owner is account-wide, not a scoped operator

Owner always carries all runners and all packs. Admin remains scopeable. Normalize
both membership columns and scope rows on creation, invitation, promotion and
directory sync; reject manual Owner scope edits. Keep stored grants canonical
instead of introducing a separate read-time Owner authorization bypass.

Promotion and Owner-access normalization preserve existing valid keys, OAuth
backing keys, rotation successors and approved device grants. Connected agents
inherit the wider membership scope without reconnecting; do not revoke credentials
or add a reconnection warning for promotion. Agent permissions remain `api_client`,
not Owner. Role reductions, suspension, removal and explicit revocation still
retire credentials. Normal reads retain pending, invitation, suspension, account,
key-revocation and expiry guards. Owner does not bypass policy, approvals, pack
trust, or account isolation. Browser sockets refresh their authorization without
invalidating sign-in sessions.

Owner demotion requires explicit resulting access. A directory-owned Owner
returns both role and access to directory reconciliation, with Viewer and
canonical no-runner access until it completes; never silently detach the member
or let a later sync overwrite a manually selected grant. Preserve suspension.

Sweep: Owner scope editors, role writes without normalized scope rows, Owner
promotions that revoke valid credentials, key scope reads without current key
validity, and tests that use scoped Owners where scoped Admins are intended.
Regression coverage: `accounts_owner_access_test.exs`, `member_role_live_test.exs`,
and existing scope/SCIM denial and isolation suites. Execution is a release gate,
not evidence supplied by a source-only review.
