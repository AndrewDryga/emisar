# Publishing the pack registry

The pack catalog is published as **immutable, versioned artifacts** to the
public-read GCS bucket `emisar-pack-registry` (provisioned in
`infra/packs_registry.tf`; see `infra/README.md`). `emisar pack install` and
`emisar pack suggest` resolve against it unauthenticated, so every pack
version/hash ever published must stay installable — publishing **appends**,
never overwrites history. Public access is GET-only for exact object paths; the
bucket root is not a supported listing or discovery endpoint.

Both steps run through `packctl`, the maintainer CLI built from `runner/cmd/packctl`
(`go build -o ../bin/packctl ./cmd/packctl` from `runner/`). It shares the runner's
module, so local verification and CI publishing use the same loader — and the same
content hash the runner enforces at load time. `packctl` is a maintainer tool, not
the host `emisar` binary, which ships operator verbs only.

## Object layout

```
v1/catalog.json                                  latest catalog (mutable pointer)
v1/catalog/<sha256>.json                         immutable catalog snapshot (content-addressed)
v1/suggest.json                                  lean suggest index (mutable pointer)
v1/schemas/{catalog,pack,action}.schema.json     immutable JSON schemas
v1/packs/<id>/<version>/<sha256>/pack.tar.gz     immutable pack tarball (content-addressed)
```

Immutability falls out of content-addressing: a tarball lives under its
`content_hash`, so identical bytes always resolve to the same object and a byte
change without a version bump lands at a different path. The two mutable
pointers are overwritten each publish; the bucket's **object versioning** keeps
every prior generation fetchable.

`content_hash` is the runner's load-time hash (`emisar pack validate` prints the
same value) — the single trust source. Install snippets pin `--hash sha256:…`
and the runner rejects any tampered tarball after download, so the public
transport adds no trust the hash doesn't already carry.

## Build

```bash
# Build the artifact tree from the repo packs dir.
packctl catalog build --packs ./packs --out ./dist

# Enforce the "preserve every version/hash" guarantee: fetch the currently
# published catalog first and pass it as --previous. The build FAILS if any
# pack changed bytes for an already-published id+version — bump the version.
curl -fsS https://registry.emisar.dev/v1/catalog.json -o ./current-catalog.json
packctl catalog build --packs ./packs --out ./dist --previous ./current-catalog.json
```

The build is deterministic: identical packs produce an identical catalog hash
and byte-identical tarballs, so re-running it is safe.

## Publish

```bash
# Auth: CI uses Workload Identity; locally use gcloud.
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)

# Preview first — no network calls.
packctl catalog publish --dir ./dist --bucket emisar-pack-registry --dry-run

# Upload. Immutable objects use an if-generation-match:0 precondition, so an
# existing object is never overwritten (a precondition failure = identical bytes
# already published = skipped). The mutable pointers are overwritten last.
packctl catalog publish --dir ./dist --bucket emisar-pack-registry
```

The publisher service account (`emisar-pack-publisher`) holds **`objectCreator`
only** — it can append new artifacts and cut a new catalog generation but cannot
delete or mutate history. The append-only guarantee is IAM-enforced, not
conventional.

## Verify

```bash
# The published content hash for a pack must equal its local validate hash.
emisar pack validate ./packs/redis          # prints "hash: sha256:…"
curl -fsS https://registry.emisar.dev/v1/catalog.json \
  | jq -r '.packs[] | select(.id=="redis") | .content_hash'

# Round-trip the published tarball back to the same hash.
curl -fsS "$(curl -fsS .../v1/catalog.json | jq -r '.packs[]|select(.id=="redis").tarball_url')" \
  | tar -xz -C /tmp/redis && emisar pack validate /tmp/redis
```

## Retiring older versions (critical fix)

When a shipped pack version carries a critical defect, retire **every** older
version so a runner still advertising an old version fails closed at dispatch.
Retirement is authored in the pack itself — a `retired_below` floor in
`pack.yaml` — so the decision and its exact floor live in the pack's git
history, get reviewed in the PR, and ship through the normal publish. It is
still release-controlled: it takes effect on the deploy that ships the fixed
pack's auto-trust, so a compromised remote catalog can neither auto-trust a
new hash nor mass-retire the fleet.

```yaml
# 1. Fix the pack, BUMP its version, and declare the floor in packs/redis/pack.yaml.
#    Everything strictly below retired_below is retired; the current version must
#    be at or above it (the build rejects current < retired_below). To retire
#    every older version, set retired_below to the new current version.
version: 0.2.4         # was 0.2.3
retired_below: 0.2.4   # 0.2.3 and earlier are now retired
```

```bash
# 2. Build against the live catalog (--previous enforces the monotonic floor:
#    the build refuses to LOWER or DROP an already-published retired_below) and
#    publish. Old tarballs stay installable — retirement blocks dispatch, not
#    installation.
curl -fsS https://registry.emisar.dev/v1/catalog.json -o ./current-catalog.json
packctl catalog build --packs ./packs --out ./dist --previous ./current-catalog.json
packctl catalog publish --dir ./dist --bucket emisar-pack-registry

# 3. Regenerate the BUNDLED catalog the portal compiles in, in the SAME
#    commit as the pack edit (retired_below is baked into PackBaseline):
cp ./dist/v1/catalog.json ../portal/apps/emisar/priv/packs/catalog.json
#    then from portal/: mix test test/emisar/catalog/pack_baseline_test.exs (apps/emisar)
#                       mix test test/emisar_web/packs_registry/cache_test.exs (apps/emisar_web)

# 4. Deploy the portal. Retirement takes effect on that deploy — the same
#    motion that ships the fix. Verify in a test account: a runner pinned to
#    the retired version now blocks with `pack_retired` at dispatch, telling
#    the operator to update the pack (an admin can still explicitly re-trust
#    the retired version on the Packs page — a deliberate, audited override).
```

Retirement is permanent and monotonic: once `retired_below` is published the
build refuses to lower or drop it, so a stale `--previous` can never un-retire
a version, and the pack always tells the full truth about its floor.

## Installing a specific version

`emisar pack install <name>=<version>` installs one published version by name,
resolving `<registry>/packs/<name>/versions/<version>/pack.tar.gz`:

```bash
emisar pack install redis=0.2.3 --hash sha256:… --dest /etc/emisar/packs
```

The version window keeps the last few published versions of each pack
auto-trusted, so a runner on a slightly-older shipped version dispatches
without landing in pending review.

**Retired versions — break-glass.** A retired version is still installable (the
immutable tarball is permanent) but is **not dispatchable** without an admin
override — defense sits at the trust gate, not installability. To pull a retired
tarball directly, use its content-addressed GCS URL from a prior catalog
generation (see Rollback for listing generations):

```bash
gcloud storage cat gs://emisar-pack-registry/v1/catalog.json#<generation> \
  | jq -r '.packs[]|select(.id=="redis").tarball_url'
```

## Serving domain (registry.emisar.dev)

The pack registry's canonical base is **`https://registry.emisar.dev`** — the
vendor-neutral serving domain. The shared HTTPS LB routes that host straight to
the same bucket (`infra/packs_registry.tf` + the host rule in `infra/lb.tf`), so
every object path resolves identically at both bases (`…/v1/catalog.json`).
`packctl` bakes `registry.emisar.dev` tarball URLs into the catalog it builds
(`defaultRegistryBaseURL`), and the portal refreshes + pins against the same base
(`EMISAR_PACK_CATALOG_URL` / the `runtime.exs` default). The old
`storage.googleapis.com/emisar-pack-registry` base still serves the SAME bytes,
so every URL ever published there keeps resolving; `packctl catalog publish`
still WRITES through the authenticated GCS API endpoint (`DefaultGCSEndpoint`) —
only the read/serve base moved.

**Deploy gate — the domain must serve BEFORE the flip ships.** The code now
defaults to `registry.emisar.dev`; do not deploy the portal (or run
`packctl catalog publish` on the new base) until the domain resolves and its
cert is ACTIVE, or the portal 302s installers to a dead host and the next
publish bakes not-yet-live URLs into an immutable catalog. Go-live (works BEFORE
the emisar.dev NS cutover — the host migrates independently):

1. `terraform apply` (TFC) — creates the backend bucket, cert, and DNS-auth.
2. Add the GoDaddy records: `terraform output pack_registry_godaddy_records`
   (A/AAAA → the LB IPs + the cert DNS-auth CNAME).
3. Wait for the `emisar-cert-registry` managed cert to be ACTIVE, then verify:
   `curl -fsSL https://registry.emisar.dev/v1/catalog.json | jq .schema_version`.
4. Deploy the portal and publish the catalog on the new base. Carried
   `previous_versions` history re-homes automatically — the build REBUILDS
   carried tarball URLs from the current base (content-addressed: version+hash
   pin the path), so there is never a mixed-host catalog to hand-edit.

Bridge option if you must deploy the code before the domain serves: set
`EMISAR_PACK_CATALOG_URL=https://storage.googleapis.com/emisar-pack-registry/v1/catalog.json`
so the portal keeps refreshing from (and pinning to) the GCS base until
`registry.emisar.dev` is live, then drop the override.

## Rollback

Immutable objects are never rolled back — they are content-addressed and
permanent. Only the mutable pointers can regress, and every prior generation is
retained by bucket versioning:

```bash
gcloud storage ls -a gs://emisar-pack-registry/v1/catalog.json      # list generations
gcloud storage cp gs://emisar-pack-registry/v1/catalog.json#<generation> \
                  gs://emisar-pack-registry/v1/catalog.json         # restore one
```

Do the same for `v1/suggest.json` if a bad suggest index shipped.
