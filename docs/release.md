# Cutting an emisar release

A release is one **product version** on the website changelog, with a matching
signed git tag and a GitHub release. The goal is that **commit history, tags, and
the changelog always line up**: every changelog entry has a tag, every tag points
at the tip commit of that version's window, and every tag is signed.

This is the canonical runbook. The `/ops-release` skill is the order of operations on
top of it.

## Versioning

- The website uses a **unified product line `vMAJOR.MINOR.PATCH`**. Pre-1.0, a
  normal feature release is a **minor bump** (`v0.24.0` → `v0.25.0`); reserve a
  patch (`v0.X.Y`) for a changelog-worthy
  hotfix on top of a release.
- These product tags are **distinct from the per-component release tags**
  (`runner-v*`, `mcp-v*`), which publish client binaries. The changelog and
  product GitHub releases use the **product** tags only; product tags also
  publish the hosted MCP Registry listing — but that publication is
  **deploy-gated**: the workflow reconciles against the version the live
  `/healthz` reports, so the public listing follows the founder's
  Confirm & Apply (within one half-hourly tick), never the tag alone.
- A version's tag points at the **last commit of its window** (the tip — usually
  `HEAD` at release time). Pick the anchor deliberately so the range
  `<previous-tag>..<anchor>` is exactly what the entry describes.
- The **app/footer version is `portal/VERSION`** — one file read by the umbrella
  `mix.exs`, both app `mix.exs`, the OTP release version, and the marketing footer
  (`Application.spec(:emisar_web, :vsn)` → `v… — built with co:op`). Bump that one
  file and every version display moves together; nothing else hardcodes the number.
  Use the bare `X.Y.0` there (no `v` — mix versions are SemVer without the prefix).

## The changelog

`portal/apps/emisar_web/lib/emisar_web/changelog.ex` is the single source — it
renders both `/changelog` and the `/changelog.xml` RSS feed, so they never drift.
Add a release by prepending **one** entry to `@entries` (newest first):

```elixir
%{
  date: ~D[2026-06-25],            # the anchor commit's date
  slug: "analytics-and-console-craft",  # kebab, unique (it's the page anchor + RSS guid)
  title: "Product analytics and the console craft pass",
  tag: "v0.25.0",                  # the product tag
  summary: "Server-side product analytics that set no tracking cookie: ..."
}
```

**The summary is plain text.** The template renders `{entry.summary}` verbatim, so
**no backticks, no Markdown** — write `emisar pack install`, not `` `emisar pack install` ``.
Lead with the mechanism, keep em-dashes sparse, and run it through
`/content-director` for voice (see that skill's `references/tone-rules.md`). This is
the opposite of the GitHub release notes, which *are* Markdown.

`apps/emisar_web/test/emisar_web/marketing_test.exs` ("the changelog renders its
entries") asserts the newest and oldest titles plus their tags — **update the newest
assertions** to the new entry when you add one.

## Tags must be signed

GitHub shows a tag as **Verified** only when it carries a valid GPG/SSH signature.
The repo signs *commits* (`commit.gpgsign true`) but **not tags** by default, and
`git tag -a` does **not** sign — only `git tag -s` does. Always create release tags
with `-s`:

```sh
git tag -s v0.25.0 <anchor-commit> -m "v0.25.0 — <title>"
git tag -v v0.25.0          # must print "Good signature"
```

To stop this recurring, set it once: `git config --local tag.gpgsign true`.

The signing key (`user.signingkey`) is already the one that signs commits, so it's
registered on the GitHub account and the tagger email matches — signed tags verify
immediately on push. A *lightweight* tag can't be signed; if you ever need to fix
one, recreate it as `git tag -s -f` (preserve the original message and tagger date
via `GIT_COMMITTER_DATE`).

**This applies to the per-component release tags too**, not just the product tags.
`runner-v*` / `mcp-v*` trigger the binary release workflows
(`runner-release.yml` / `mcp-release.yml` fire on the tag push). The tag is
created and verified locally first; an unsigned tag is rejected. Cut component
tags with `-s` as well:

```sh
git tag -s runner-vX.Y.Z <commit> -m "runner vX.Y.Z"
git tag -v runner-vX.Y.Z          # "Good signature"
git push origin runner-vX.Y.Z     # release workflow builds + attests
```

`git config --local tag.gpgsign true` (above) covers these too. Release workflows
also verify GitHub's signature result and require the tag to target current
`main`; a failed tag workflow is recovered by rerunning that same Actions run,
not by moving or recreating the tag.

## GitHub release notes

`gh release create` notes render as **Markdown** (unlike the changelog summary). A
good release body is a short lead sentence plus grouped highlights — Security,
Operability, Packs, Marketing — only the groups that apply. Write it through
`/content-director` too; same voice, richer structure. Keep it honest and concrete;
no inflated security claims.

## Order of operations

1. **Pick the version + anchor.** `git tag -l 'v*.*.0' | sort -V | tail -1` is the
   previous release; review `git log <previous>..HEAD --format='%h %ad %s' --date=short`
   and choose the next version (minor bump) and the anchor commit (usually `HEAD`).
2. **Group the window into themes** from that log — the raw material for both the
   changelog summary and the release notes.
3. **Write the changelog entry** (plain-text summary, via `/content-director`) and
   prepend it to `@entries`.
4. **Bump `portal/VERSION`** to the new `X.Y.0` (no `v`). That one file is read by
   the umbrella, both apps, the OTP release version, and the marketing footer, so
   every version display moves in lockstep.
5. **Roll the BUSL Change Date** in `LICENSE.md` to the release date plus three
   years. Each released version carries its own conversion promise.
6. **Update the marketing test** newest-entry assertions.
7. **Reconcile the bundled pack catalog with production.** Fetch `https://registry.emisar.dev/v1/catalog.json`, build the current packs with that file as `packctl catalog build --previous`, and copy the result to `portal/apps/emisar/priv/packs/catalog.json`. This removes unpublished intermediate versions left by canceled releases and makes the later CD byte check deterministic. See `packs/PUBLISHING.md` for the exact commands.
8. **Gate** from `portal/`: `mix compile --warnings-as-errors && mix format --check-formatted && mix credo && ../.agent/scripts/check-portal-test-output.sh`. Green before committing. Never pipe the format/compile checks through `head`/`tail` (it masks the exit code).
9. **Commit** the changelog, version, license date, test, and reconciled catalog — one focused commit
   (e.g. `release: v0.25.0 — <title>`).
10. **Push the commit** (`git push origin main`). *Outward-facing — confirm first.*
11. **Create the signed tag** at the anchor (`git tag -s …`) and `git tag -v` it.
12. **Push the tag** (`git push origin v0.25.0`). *Outward-facing — confirm first.*
13. **Write the release notes** (Markdown, via `/content-director`) and **create the
    GitHub release**: `gh release create v0.25.0 --verify-tag --title "v0.25.0 — <title>" --notes-file <file>`. *Outward-facing — confirm first.*
14. **Record** the completed release in `portal/.agent/LOG.md`.

## Verify

- `git tag -v v0.25.0` → Good signature, points at the anchor.
- `gh release view v0.25.0` → the release is live with the notes.
- `/changelog` renders the new entry at the top; `/changelog.xml` includes it.
- The marketing test is green.

## Verifying a downloaded binary (the recipe users run)

The `runner-*`/`mcp-*` workflows already publish **SLSA-3 build provenance**
(`actions/attest-build-provenance@v4`, Sigstore-signed) and a `SHA256SUMS`
(`SHA256SUMS-MCP` for the bridge) on every release. This is the recipe a security
team runs before installing — keep it in sync with what `/trust#release-integrity`
publishes:

```sh
# provenance — proves the artifact was built by our workflow, from our source
gh attestation verify emisar-<version>-linux-amd64.tar.gz --owner andrewdryga

# checksum — proves the bytes match what we published
sha256sum -c SHA256SUMS                 # SHA256SUMS-MCP for the bridge
```

The runner and MCP release workflows execute the same checksum and provenance
verification before publication. The portal `/trust` "Release integrity"
section quotes these commands for customers.
