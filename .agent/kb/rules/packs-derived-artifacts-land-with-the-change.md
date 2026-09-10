# Rule: a pack change lands with its derived artifacts and a publishable version

**Rule.** A pack add or change ships in one commit with everything derived
from it: the regenerated bundled catalog artifact, the refreshed cross-language
hash golden when `redis/` or `cassandra/` bytes moved, and a `version` bump
whenever the pack's contract changed. Versions are dot-numeric only.

**Why.** Since `4fe4349d` the portal never scans `packs/`. It seeds a fresh VM
from `portal/apps/emisar/priv/packs/catalog.json`, and `Emisar.Catalog.PackBaseline`
reads auto-trust from the installed snapshot that the configured published
catalog refreshes — so a stale artifact makes a fresh VM auto-pin the old set
until its first successful refresh. The registry publishes by appending: a byte
change for an already-published `id/version` fails the build until the version
moves. And a version with a SemVer suffix validates, installs, advertises,
produces a valid `pack_ref`, and can be signed — yet can never be published,
because `packctl catalog build` parses each component as an integer for the
retirement compare. Four things judge a version and three differ on purpose:
the loader is permissive (a third-party pack may label itself anything), the
portal's `runner_action` column matches whatever a runner advertised, and the
MCP projection accepts suffixes; only the catalog build is strict.

**The artifact.** Fetch `https://registry.emisar.dev/v1/catalog.json`, run
`packctl catalog build --packs ./packs --out ./dist/packs --previous <that file>`,
copy the built `catalog.json` over `portal/apps/emisar/priv/packs/catalog.json`,
and run `mix test test/emisar/catalog/pack_baseline_test.exs
test/emisar/catalog/published_registry/cache_test.exs` from `apps/emisar`. The
live catalog is the only valid history source: the committed artifact can carry
an unpublished intermediate version forward after a canceled release, and
without `--previous` every pack's version-window history rebuilds empty and the
monotonic guard on `retired_below` is skipped. Use the committed catalog only
when there is no live history — an empty registry, or a missing/unparseable
live pointer (CD's `packs-publish` falls back automatically; restore a bucket
version when the exact prior history matters, `packs/PUBLISHING.md` → Rollback).
`packctl` is the maintainer tool, built from `runner/`
(`go build -o ../bin/packctl ./cmd/packctl`); `bin/emisar` runs `pack validate`.

**The hash golden.** `apps/emisar/test/emisar/catalog/published_registry_test.exs`
pins the `content_hash` of `redis` (exec-only) and `cassandra` (script-kind)
byte-for-byte — the proof that `Emisar.Catalog.PublishedRegistry` and the Go
runner hash a pack identically. `emisar pack validate` does not run it, so any
byte change to those two packs, including a catalog-wide sweep that touches
their text, leaves the portal build red from the packs side. `./run pack hashes`
detects the drift and the staged commit check calls it whenever those bytes
change (failing open only when `bin/emisar` is absent); refresh both literals
with `./run pack hashes --write` and commit them with the pack change.

**Versions.** Brand-new packs start at `0.1.0` and need no bump until first
committed. `0.3.15` is a version; `1.0.0-rc1` and `2.0.0+build` are not, and
`./run check packs` refuses them at authoring (`validatePackVersions`). The same
parser judges `retired_below`.

**Portal pickup.** There is no list to edit in `portal/`. The installed
snapshot — boot-seeded from the bundled artifact, refreshed from the configured
registry — drives the marketing `/packs` pages, the sitemap, and the registry
API. `./run pack sync <name> --fix` rebuilds the artifact and focused tests; the
active `./run serve` recompiles it. Confirm against `./run urls` with
`/packs.json` and `/packs/<name>`. A packaged release image needs a rebuild;
production re-bakes on the next deploy.

**Enforced.** `./run gate packs` byte-compares a fresh catalog build with the
committed artifact and runs the focused Portal catalog tests; `./run check packs`
rejects non-numeric versions; the staged commit check runs the hash golden when
`redis/` or `cassandra/` bytes change.
