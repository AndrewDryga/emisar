# Rule: a private pack has no enforceable retirement floor

**Rule.** A pack that is never published to the configured catalog cannot be
retired. `retired_below` in a private pack's manifest is inert text: no dispatch
is refused and no fleet is moved off the bad version. The **delivery re-pin is
the whole enforcement**, so a security fix to a private pack lands together with
the apply that ships it. For the same reason **every byte change to a private
pack bumps its `version`** — routine or not, and whatever the public-catalog
retirement rule allows for published packs.

**Why the floor cannot reach it.** The portal builds its watermark map from
catalog entries alone: `PublishedRegistry.Catalog.put_pack_trust/2`
(`portal/apps/emisar/lib/emisar/catalog/published_registry/catalog.ex`) reads
each entry's `retired_below` into `trust.retired_below`, and nothing else writes
that map. `PackBaseline.retired?/2` is
`version_retired?(version, Map.get(retired_below(), pack_id))`, and
`version_retired?(_, nil)` returns `false` — so a pack absent from the map is
never retired. The compare is not reached, which means the fail-closed
unparseable-version branch never applies to it either.

`infra/packs/emisar-admin` is the private pack we ship today. It appears in
neither `portal/apps/emisar/priv/packs/catalog.json` nor the admin runner's
`infra/runtime/admin-runner/pack-pins.txt` (that file pins published packs the
runner installs from the registry by hash). Its bytes reach the host from
`infra/compute.tf`, which embeds `infra/packs/emisar-admin/**` with `filebase64`
into cloud-init. So the fixed bytes exist on the instance only after a Terraform
apply replaces them — **a committed private-pack fix that has not been applied
is not deployed.** `7cdee7cd9` raised the admin pack's `member_invite` from
`medium` to `high` because seating a new Owner was auto-running under the shipped
default policy; nothing could have failed 0.1.4 closed behind it, and only the
apply carrying 0.1.5 ended the exposure.

**Why every byte change bumps the version.** The trust baseline keys on
`(pack id, version, hash)` and the portal verifies each dispatch against the
exact triple the account trusts. Editing a private pack without moving `version`
makes one version advertise two hashes: the trusted record no longer describes
the bytes that run, and the operator who re-trusts the new hash on the Packs page
gets no version change to tell them what moved. `874541582` changed
`infra/packs/emisar-admin/actions/analytics_executive.yaml` while `pack.yaml`
still read 0.1.5; the later 0.1.6 bump is what resolved it. The published-catalog
rule that lets a routine change ride an existing version has no equivalent here,
because there is no publication step to refuse the collision.

**Sweep target.** `infra/packs/emisar-admin/` — a commit that changes any file
under it without moving `version` in `pack.yaml`, a `retired_below` added there
as though it enforced something, or a security fix committed with no matching
infra apply recorded.

**How it's enforced.** Review, not tooling: the packs gate never sees
`infra/packs/`, and the publication path that refuses a same-version byte change
is exactly what a private pack skips. Check `git log --stat` for the pack
directory against `pack.yaml`'s `version` when reviewing an admin-pack change.
