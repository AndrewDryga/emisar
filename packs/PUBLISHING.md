# Publishing the pack registry

The pack catalog is published as **immutable, versioned artifacts** to the
public-read GCS bucket `emisar-pack-registry` (provisioned in
`infra/packs_registry.tf`; see `infra/README.md`). `emisar pack install` and
`emisar pack suggest` resolve against it unauthenticated, so every pack
version/hash ever published must stay installable — publishing **appends**,
never overwrites history.

Both steps run through the runner CLI, so local verification and CI publishing
use the same code and the same content hash the runner enforces at load time.

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
emisar pack catalog build --packs ./packs --out ./dist

# Enforce the "preserve every version/hash" guarantee: fetch the currently
# published catalog first and pass it as --previous. The build FAILS if any
# pack changed bytes for an already-published id+version — bump the version.
curl -fsS https://storage.googleapis.com/emisar-pack-registry/v1/catalog.json -o ./current-catalog.json
emisar pack catalog build --packs ./packs --out ./dist --previous ./current-catalog.json
```

The build is deterministic: identical packs produce an identical catalog hash
and byte-identical tarballs, so re-running it is safe.

## Publish

```bash
# Auth: CI uses Workload Identity; locally use gcloud.
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)

# Preview first — no network calls.
emisar pack catalog publish --dir ./dist --bucket emisar-pack-registry --dry-run

# Upload. Immutable objects use an if-generation-match:0 precondition, so an
# existing object is never overwritten (a precondition failure = identical bytes
# already published = skipped). The mutable pointers are overwritten last.
emisar pack catalog publish --dir ./dist --bucket emisar-pack-registry
```

The publisher service account (`emisar-pack-publisher`) holds **`objectCreator`
only** — it can append new artifacts and cut a new catalog generation but cannot
delete or mutate history. The append-only guarantee is IAM-enforced, not
conventional.

## Verify

```bash
# The published content hash for a pack must equal its local validate hash.
emisar pack validate ./packs/redis          # prints "hash: sha256:…"
curl -fsS https://storage.googleapis.com/emisar-pack-registry/v1/catalog.json \
  | jq -r '.packs[] | select(.id=="redis") | .content_hash'

# Round-trip the published tarball back to the same hash.
curl -fsS "$(curl -fsS .../v1/catalog.json | jq -r '.packs[]|select(.id=="redis").tarball_url')" \
  | tar -xz -C /tmp/redis && emisar pack validate /tmp/redis
```

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
