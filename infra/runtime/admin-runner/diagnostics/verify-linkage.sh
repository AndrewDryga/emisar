#!/bin/bash
# Repository-owned qualification, not an artifact-supplied executable.
set -euo pipefail
bundle=$1
shift
for executable in "$@"; do
  resolved=$("$bundle/lib/loader" --library-path "$bundle/lib" --list "$executable")
  printf '%s\n' "$resolved"
  # The qualifier base has libc too. A successful default-path fallback must
  # fail qualification instead of hiding a dependency absent on COS.
  awk -v prefix="$bundle/" '
    /=>/ {if (index($3,prefix) != 1) exit 1; next}
    /^[[:space:]]*\// {if (index($1,prefix) != 1) exit 1}
  ' <<< "$resolved"
done
