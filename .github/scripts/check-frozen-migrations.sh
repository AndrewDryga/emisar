#!/usr/bin/env bash
set -euo pipefail

event=${1:?usage: check-frozen-migrations.sh EVENT BASE}
base=${2:-}

if [ -z "$base" ] || [ "$base" = "0000000000000000000000000000000000000000" ] || ! git cat-file -e "$base" 2>/dev/null; then
  echo "::error::cannot verify frozen migrations: base commit is unavailable"
  exit 1
fi

if [ "$event" = pull_request ]; then
  from=$(git merge-base "$base" HEAD)
else
  from=$base
fi

changed=$(mktemp)
trap 'rm -f "$changed"' EXIT
git diff --no-renames --name-status -z --diff-filter=MDT "$from" HEAD -- \
  ':(glob)portal/apps/*/priv/repo/migrations/*.exs' >"$changed"

violations=()
while IFS= read -r -d '' status && IFS= read -r -d '' path; do
  violations+=("$status $path")
done <"$changed"

if [ ${#violations[@]} -gt 0 ]; then
  echo "::error::committed migrations are frozen; add a new forward migration instead:"
  printf '  - %s\n' "${violations[@]}"
  exit 1
fi

echo "ok: committed migrations are unchanged"
