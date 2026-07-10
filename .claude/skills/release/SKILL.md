---
name: release
description: Cut an emisar product release end to end — pick the version, write the changelog entry and GitHub release notes with /content-director, gate, commit, create a SIGNED tag at the right commit, push, and publish the GitHub release. Use when the user wants to "cut a release", "ship vX.Y.0", tag a version, or update the website changelog for a new release. Keeps commit history, tags, and the changelog in lockstep.
effort: medium
argument-hint: "[vX.Y.0] [anchor-commit]"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Cut a release

Releasing is **outward-facing**. This skill does all the local work — version,
changelog, gate, commit, signed tag — but **stops to confirm before each step that
leaves the machine**: `git push`, pushing the tag, and `gh release create`. Never
push or publish without an explicit go-ahead.

## Read first

This skill is self-contained — the full order of operations is below. `docs/release.md`
is the deeper engineering runbook (it sits with the other `docs/*.md`, which are
local-only); read it when present for the worked changelog-entry example and the
tag-signing details. Either way, **cross-read the current
`portal/apps/emisar_web/lib/emisar_web/changelog.ex`** to match the entry shape and
the voice of the existing entries before writing a new one.

## The things that are easy to get wrong

1. **Tags must be signed** (`git tag -s`, then `git tag -v` shows *Good signature*).
   `git tag -a` does **not** sign; an unsigned tag shows as *unverified* on GitHub.
   The repo signs commits but not tags by default.
2. **The changelog summary is plain text** — no backticks, no Markdown; the HEEx
   renders it verbatim. **The GitHub release notes are Markdown** — headings, lists,
   and code fences are fine there. Two surfaces, two rules.
3. **Product tags `vX.Y.0`** — not the component `portal-v*`/`runner-v*`/`mcp-v*`
   tags. The changelog and GitHub releases use the product line only.
4. **The tag points at the tip commit of the version's window** so history ↔ tags ↔
   changelog line up. Default anchor is `HEAD`.
5. **Bump `portal/VERSION`** in the release commit — one file feeds the umbrella,
   both apps, the OTP release version, and the marketing footer (`v… — built with
   co:op`). Forget it and the footer shows the last version forever.

## Order of operations

1. **Version + anchor.** Previous release = `git tag -l 'v*.*.0' | sort -V | tail -1`.
   Review `git log <previous>..HEAD --format='%h %ad %s' --date=short`. Choose the
   next version (minor bump pre-1.0) and the anchor commit. Honor an explicit
   `vX.Y.0` / commit passed as arguments; otherwise propose them and confirm.
2. **Group the window into themes** from that log.
3. **Changelog entry** — put on `/content-director` and write the `@entries` map
   (`date` = anchor's date, unique kebab `slug`, `title`, `tag`, **plain-text**
   `summary`, mechanism-led, sparse em-dashes). Prepend it, newest first.
4. **Bump `portal/VERSION`** to the new `X.Y.0` (no `v`) — feeds the apps, the OTP
   release version, and the marketing footer in one edit.
   Also **roll the BUSL `Change Date` in the root `LICENSE.md`** to the release date
   + 3 years (`Change Date: YYYY-MM-DD`). BUSL applies per version — each release's
   LICENSE states when THAT version converts to Apache-2.0; a stale date quietly
   promises an earlier conversion for everything shipped after it.
5. **Marketing test** — update the newest-entry assertions in
   `apps/emisar_web/test/emisar_web/marketing_test.exs` ("the changelog renders its
   entries").
6. **Gate** from `portal/`:
   `mix compile --warnings-as-errors && mix format --check-formatted && mix credo && mix test`.
   Green before committing. Run compile/format as standalone commands — never pipe
   them through `head`/`tail`, which hides the exit code.
7. **Commit** the changelog + version bump — one focused commit, Co-Authored-By trailer.
8. **Push the commit.** *Confirm first.*
9. **Signed tag** at the anchor: `git tag -s vX.Y.0 <commit> -m "vX.Y.0 — <title>"`,
   then `git tag -v vX.Y.0`. (Offer `git config --local tag.gpgsign true` so it
   stops recurring.)
10. **Push the tag.** *Confirm first.*
11. **Release notes** — `/content-director` again, Markdown this time: a short lead
    plus grouped highlights (only the groups that apply). Then
    `gh release create vX.Y.0 --verify-tag --title "vX.Y.0 — <title>" --notes-file <file>`.
    *Confirm first.*
12. **Record** the version → anchor hash in `portal/.agent/VERSIONS.md`; add a
    `portal/.agent/LOG.md` line.

## Verify and report

`git tag -v vX.Y.0` (Good signature), `gh release view vX.Y.0` (live), `/changelog`
shows the new entry on top, marketing test green. Report what shipped, the tag and
its commit, and the release URL.
