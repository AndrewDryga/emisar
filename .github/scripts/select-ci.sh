#!/usr/bin/env bash
set -euo pipefail

event=${1:?usage: select-ci.sh EVENT BASE}
base=${2:-}
output=${GITHUB_OUTPUT:-/dev/stdout}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

files=$(mktemp)
trap 'rm -f "$files"' EXIT

# Git paths are arbitrary bytes except NUL. Keep them NUL-delimited from git
# through the read loop: newline-delimited command substitution lets a quoted or
# newline-bearing filename alter which required checks run.
if [ -z "$base" ] || [ "$base" = "0000000000000000000000000000000000000000" ] || ! git cat-file -e "$base" 2>/dev/null; then
  printf '__run_all__\0' >"$files"
elif [ "$event" = "pull_request" ]; then
  git diff --no-renames --name-only -z "$(git merge-base "$base" HEAD)" HEAD >"$files"
else
  git diff --no-renames --name-only -z "$base" HEAD >"$files"
fi

portal=false; runner=false; mcp=false; tools=false; packs=false; infra=false; deps=false; workflows=false; mcp_listing=false
portal_release=false; packs_release=false

while IFS= read -r -d '' file; do
  [ -n "$file" ] || continue
  case "$file" in
    __run_all__)
      portal=true; runner=true; mcp=true; tools=true; packs=true; infra=true; deps=true; workflows=true; mcp_listing=true
      portal_release=true; packs_release=true
      ;;
  esac

  pack_source=false
  case "$file" in
    packs/AGENTS.md|packs/CLAUDE.md|packs/PUBLISHING.md) ;;
    packs/*) pack_source=true ;;
  esac

  # install.sh and real pack sources are compile-time portal inputs. Top-level
  # pack documentation is not a registry artifact and must not move catalog
  # pointers merely because publishing guidance changed.
  case "$file" in
    portal/*|.dockerignore|install.sh|install-mcp.sh|.tool-versions)
      portal=true; portal_release=true
      ;;
    .trivyignore.yaml) portal=true ;;
    .agent/scripts/check-portal-test-output.sh) portal=true ;;
  esac
  if [ "$pack_source" = true ]; then
    portal=true; portal_release=true
  fi

  case "$file" in runner/*|install.sh|README.md|go.work|go.work.sum) runner=true ;; esac
  case "$file" in mcp/*|install-mcp.sh|go.work|go.work.sum) mcp=true ;; esac
  case "$file" in server.json) mcp_listing=true ;; esac
  case "$file" in tools/*|go.work|go.work.sum) tools=true ;; esac
  case "$file" in
    runner/internal/packs/*|runner/pkg/packspec/*|runner/pkg/actionspec/*|runner/pack.go|runner/main.go|runner/go.mod|runner/go.sum|go.work|go.work.sum)
      packs=true
      ;;
  esac
  if [ "$pack_source" = true ]; then packs=true; fi
  case "$file" in
    runner/internal/packs/*|runner/internal/catalog/*|runner/cmd/packctl/*|runner/pkg/packspec/*|runner/pkg/actionspec/*|runner/pack.go|runner/main.go|runner/go.mod|runner/go.sum|go.work|go.work.sum)
      packs_release=true
      ;;
  esac
  if [ "$pack_source" = true ]; then packs_release=true; fi

  case "$file" in infra/*) infra=true ;; .tool-versions) infra=true ;; esac
  case "$file" in
    portal/mix.lock|runner/go.mod|runner/go.sum|mcp/go.mod|mcp/go.sum|tools/go.mod|tools/go.sum|portal/.agent/scripts/package-lock.json|portal/.agent/scripts/package.json|.dep-age-allow|tools/cmd/depgate/*)
      deps=true
      ;;
  esac
  case "$file" in .github/workflows/*|.github/scripts/*|.github/dependabot.yml) workflows=true ;; esac
done <"$files"

if [ "$workflows" = true ]; then
  portal=true; runner=true; mcp=true; tools=true; packs=true; infra=true; deps=true; mcp_listing=true
fi

# Reusable CI defines the tested artifact, so changing it republishes. CD only
# transports that artifact and queues every successful main commit already; a
# CD-only edit validates every gate but must not publish identical image bytes.
# Pack publication remains tied to actual pack bytes.
workflow_delivery=false
while IFS= read -r -d '' file; do
  case "$file" in
    .github/workflows/ci.yml) workflow_delivery=true ;;
  esac
done <"$files"
if [ "$workflow_delivery" = true ]; then
  portal_release=true
fi

modules=()
if [ "$runner" = true ]; then modules+=(\"runner\"); fi
if [ "$mcp" = true ]; then modules+=(\"mcp\"); fi
if [ "$tools" = true ]; then modules+=(\"tools\"); fi
go_modules="[$(IFS=,; echo "${modules[*]-}")]"

{
  echo "portal=$portal"
  echo "packs=$packs"
  echo "infra=$infra"
  echo "deps=$deps"
  echo "workflows=$workflows"
  echo "mcp_listing=$mcp_listing"
  echo "go_modules=$go_modules"
  echo "portal_release=$portal_release"
  echo "packs_release=$packs_release"
} >>"$output"

mark() { if [ "$1" = true ]; then echo run; else echo skip; fi; }
{
  echo "### Gates for this change"
  echo "| Area | |"
  echo "|---|---|"
  echo "| Portal - Test | $(mark "$portal") |"
  echo "| Portal - Image | $(mark "$portal") |"
  echo "| Go - Runner | $(mark "$runner") |"
  echo "| Go - MCP | $(mark "$mcp") |"
  echo "| Go - Tools | $(mark "$tools") |"
  echo "| Packs - Validate | $(mark "$packs") |"
  echo "| Terraform - Validate | $(mark "$infra") |"
  echo "| Dependencies - Release age | $(mark "$deps") |"
  echo "| Actions - Validate workflows | $(mark "$workflows") |"
  echo "| Portal - MCP Registry Listing | $(mark "$mcp_listing") |"
} >>"$summary"
