---
name: deps-audit
description: Audit portal/ hex dependencies for supply-chain risk — retired/yanked packages, known advisories, unexpected git/path deps, and vetting a dependency before adding it. Use before adding a dep, before a release, or periodically. emisar is a security product; every new dependency is attack surface.
effort: medium
argument-hint: "[package to vet, or omit for a full sweep]"
allowed-tools: Read, Grep, Glob, Bash, WebFetch
---

# Dependency audit

A new dependency is code you didn't write running with your privileges. For a
security product the bar is: **do we truly need it, and is it trustworthy** — not
"does it work."

## Built-in checks (no install needed)

```sh
cd portal
mix hex.audit       # retired/deprecated packages in the lock
mix hex.outdated    # available updates; age alone is not a reason to bump
mix deps.audit      # version-matched advisory database
mix sobelow --root apps/emisar_web --config
```

## Review the lockfile

- **Non-hex deps:** any `:git` or `:path` entries in `mix.lock` / `mix.exs`? Each is
  un-audited-by-hex code — justify or replace with a released package.
- **New since last release:** `git diff <last-tag> -- mix.lock` — scan added/bumped
  packages, including transitive ones, for anything unexpected.
- **Provenance:** is the package widely used and maintained? Unmaintained or
  single-commit packages are risk.

## Release age (the too-fresh gate)

A dependency release published hours ago is a supply-chain risk — a compromised
maintainer account, a typosquat, a rushed malicious minor — not harmless churn.
So a bumped version must clear a release-age window before it can merge.

- **Enforcement** is CI plus the resolver. Hex's `HEX_COOLDOWN=7d` prevents new
  resolution from selecting very fresh releases, but lock-pinned versions
  bypass it by design. Go has no equivalent. Dependabot `cooldown` controls
  only PRs Dependabot opens; it is not a general boundary.
- **The gate:** `tools/cmd/depgate` runs from the reusable CI workflow on every
  supported manifest/lockfile change. It diffs against the base and rejects an
  added/upgraded version younger than its policy window: **patch 7d · minor 14d
  · major 30d**. Run it locally from `tools/`:

  ```sh
  go run ./cmd/depgate check --base origin/main
  ```
- **Adding/bumping a dep:** prefer a version already past its window, or expect
  the gate to hold the PR until it ages. For an urgent security fix that can't
  wait, add an audited entry to `.dep-age-allow` (ecosystem · package · version ·
  reason — reason is mandatory) and remove it once the version has aged out.

## Advisories

For a flagged or suspect package, look up its advisories (GitHub Advisory DB /
`hexdocs`/`hex.pm` — version-matched via `mix.lock`), then check whether the
vulnerable code path is actually reached here. Pin or upgrade; don't bump blindly.

`mix_audit` and `sobelow` are already dev/test dependencies and both run in CI.
Do not add a parallel scanner without a concrete coverage gap.

## Vet-before-add (the real lever)

Before adding a dependency: is it needed, or do stdlib / an existing dep / a few
lines cover it (prime directive — no bloat)? If you add it, **wrap its API behind a
project-owned module (IL-19)** so it's swappable and the blast radius is contained.

## Output

`package · risk · evidence · action`. Lead with anything retired or advisory-flagged.
Pairs with `/security-engineer` for code-level review of how a dep is used.
