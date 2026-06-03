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
mix hex.outdated    # how far behind we are (stale = unpatched)
```

## Review the lockfile

- **Non-hex deps:** any `:git` or `:path` entries in `mix.lock` / `mix.exs`? Each is
  un-audited-by-hex code — justify or replace with a released package.
- **New since last release:** `git diff <last-tag> -- mix.lock` — scan added/bumped
  packages, including transitive ones, for anything unexpected.
- **Provenance:** is the package widely used and maintained? Unmaintained or
  single-commit packages are risk.

## Advisories

For a flagged or suspect package, look up its advisories (GitHub Advisory DB /
`hexdocs`/`hex.pm` — version-matched via `mix.lock`), then check whether the
vulnerable code path is actually reached here. Pin or upgrade; don't bump blindly.

## Heavier scanning (not currently installed)

There's no `mix_audit` or `sobelow` in the dep stack. If the user wants continuous
scanning, offer to add them as `:dev`/`:test` deps:
- `:mix_audit` — checks deps against an advisory DB (`mix deps.audit`).
- `:sobelow` — Phoenix-focused static security scan (`mix sobelow`).
Don't claim to have run them unless they're added.

## Vet-before-add (the real lever)

Before adding a dependency: is it needed, or do stdlib / an existing dep / a few
lines cover it (prime directive — no bloat)? If you add it, **wrap its API behind a
project-owned module (IL-19)** so it's swappable and the blast radius is contained.

## Output

`package · risk · evidence · action`. Lead with anything retired or advisory-flagged.
Pairs with `/security-engineer` for code-level review of how a dep is used.
