# Emisar customer skills

These skills are standalone onboarding tools for Emisar customers. They use
public Emisar installers, documentation, portal flows, and installed CLI
interfaces. Installing one never requires cloning or forking this repository.

## Available skills

| Skill | Purpose |
| --- | --- |
| [`install-emisar`](install-emisar/SKILL.md) | Install, configure, repair, and certify the runner, packs, and MCP bridge end to end. |

## Install directly

The commands below install the current `main` version. For a repeatable rollout,
replace `main` with a reviewed release tag or commit SHA.

### Codex

```sh
(
  set -eu
  skill_dir="${CODEX_HOME:-$HOME/.codex}/skills/install-emisar"
  mkdir -p "$skill_dir"
  tmp="$(mktemp "$skill_dir/.SKILL.md.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  curl --fail --silent --show-error --location \
    https://raw.githubusercontent.com/AndrewDryga/emisar/main/skills/install-emisar/SKILL.md \
    -o "$tmp"
  grep -q '^name: install-emisar$' "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$skill_dir/SKILL.md"
  trap - EXIT HUP INT TERM
)
```

Start a new Codex session, then ask it to use `$install-emisar` on the target
environment.

### Claude Code

```sh
(
  set -eu
  skill_dir="$HOME/.claude/skills/install-emisar"
  mkdir -p "$skill_dir"
  tmp="$(mktemp "$skill_dir/.SKILL.md.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  curl --fail --silent --show-error --location \
    https://raw.githubusercontent.com/AndrewDryga/emisar/main/skills/install-emisar/SKILL.md \
    -o "$tmp"
  grep -q '^name: install-emisar$' "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$skill_dir/SKILL.md"
  trap - EXIT HUP INT TERM
)
```

Start a new Claude Code session, then run `/install-emisar` for the target
environment.

Re-run the same command to update a skill. Review changes before updating any
pinned or centrally managed customer installation.
