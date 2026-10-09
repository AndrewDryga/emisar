#!/bin/sh
set -eu

limit=$1
shift
# Runner validation bounds elements but required arrays may still be empty.
[ "$#" -gt 0 ] || { printf '%s\n' 'At least one search term is required.' >&2; exit 2; }
for term do
  case "$term" in
    *[![:space:]]*) ;;
    *) printf '%s\n' 'Search terms must not be empty or whitespace-only.' >&2; exit 2 ;;
  esac
done
# No splitting/eval: negative qualifiers and flag-looking terms stay operands.
exec gh search prs --limit "$limit" --json number,title,repository,author,state,createdAt,updatedAt -- "$@"
