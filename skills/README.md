# Emisar customer skills

These skills are standalone onboarding tools for Emisar customers. They use
public Emisar installers, documentation, portal flows, and installed CLI
interfaces. Installing one never requires cloning or forking this repository.

## Available skills

| Skill | Purpose |
| --- | --- |
| [`install-emisar`](install-emisar/SKILL.md) | Install, configure, repair, and certify the on-host runner and its packs end to end. |
| [`connect-llm`](connect-llm/SKILL.md) | Connect an LLM or MCP client — the stdio bridge or a cloud connector — and certify the connection. |
| [`author-pack`](author-pack/SKILL.md) | Author, validate, test, distribute, and certify a custom action pack — directory installs or a private registry. |

## Install directly

Set `skill` to the skill you want from the table above. The commands below
install the current `main` version; for a repeatable rollout, replace `main`
with a reviewed release tag or commit SHA.

### Codex

```sh
(
  set -eu
  skill="install-emisar"
  skill_dir="${CODEX_HOME:-$HOME/.codex}/skills/$skill"
  mkdir -p "$skill_dir"
  tmp="$(mktemp "$skill_dir/.SKILL.md.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/AndrewDryga/emisar/main/skills/$skill/SKILL.md" \
    -o "$tmp"
  grep -q "^name: $skill\$" "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$skill_dir/SKILL.md"
  trap - EXIT HUP INT TERM
)
```

Start a new Codex session, then ask it to use the skill by name (for example
`$install-emisar`) on the target environment.

### Claude Code

```sh
(
  set -eu
  skill="install-emisar"
  skill_dir="$HOME/.claude/skills/$skill"
  mkdir -p "$skill_dir"
  tmp="$(mktemp "$skill_dir/.SKILL.md.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/AndrewDryga/emisar/main/skills/$skill/SKILL.md" \
    -o "$tmp"
  grep -q "^name: $skill\$" "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$skill_dir/SKILL.md"
  trap - EXIT HUP INT TERM
)
```

Start a new Claude Code session, then run the matching slash command (for
example `/install-emisar`) for the target environment.

Re-run the same command to update a skill. Review changes before updating any
pinned or centrally managed customer installation.
