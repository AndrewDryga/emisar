#!/bin/sh
set -eu

# -e handles command replies, but redis-cli can still exit zero after an AUTH
# or SELECT failure. These finite calls have no benign stderr warning path.
# Keep ordinary stdout streaming while collecting the diagnostic and exit.
run_cli() {
    cli_status=0
    cli_errors=
    {
        cli_errors=$(redis-cli -e "$@" 2>&1 1>&3) || cli_status=$?
    } 3>&1 || cli_status=$?
    if [ -n "$cli_errors" ]; then
        [ "$cli_status" -ne 0 ] || cli_status=1
        printf '%s\n' "$cli_errors" >&2
    fi
    return "$cli_status"
}

# The cluster manager bypasses -e and puts its diagnostics on stdout. Preserve
# its native exit, but publish its failed report only on the error channel.
if [ "${1:-}" = --cluster ] && [ "${2:-}" = check ]; then
    cluster_status=0
    cluster_output=$(run_cli "$@") || cluster_status=$?
    if [ -n "$cluster_output" ]; then
        if [ "$cluster_status" -eq 0 ]; then
            printf '%s\n' "$cluster_output"
        else
            printf '%s\n' "$cluster_output" >&2
        fi
    fi
    exit "$cluster_status"
fi

run_cli "$@"
