# Rule: external integration files need explicit proof before deletion

**Rule.** Treat repository files designed to be sourced, linked, loaded, or
discovered by tools outside the checkout as public integration entry points.
No in-repository reference is not evidence that they are unused. Before deleting
one, confirm its external consumers with the owner or replace the integration in
the same change.

**Why.** Shell startup files, editor configuration, local environment hooks, and
similar entry points are called from user- or machine-owned configuration that a
repository search cannot see. Deleting one can silently break every new terminal
or development session while leaving all repository checks green.

**Good.** Ask whether a root `.shell` file is sourced from a contributor's Zsh
configuration, then retain it or migrate that caller deliberately.

**Bad.** Delete an externally sourced dotfile because `rg` finds no callers in
the repository, or because one command inside it appears outdated.

**Sweep.** Before repository-hygiene deletion passes, inspect root dotfiles and
files whose comments describe sourcing, linking, installation, or automatic
discovery. Separate a stale command inside an integration file from evidence
that the integration file itself is stale.

**Enforced.** Owner confirmation and review; external consumers are not reliably
visible to a repository-only automated check.
