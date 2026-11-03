#!/usr/bin/env bash
# Run the one Medusa command an action names, with the checks Medusa itself
# skips: it exits 0 after a failed snapshot, after a restore with nothing to
# restore, and after a latest-backup report that could not be produced.
set -euo pipefail

operation=${1:-}
if [ "$#" -gt 0 ]; then
    shift
fi

# Medusa prints results on stdout and logs on stderr. Stream both as they come,
# and keep a copy of the log for the checks below.
log=$(mktemp)
trap 'rm -f "$log"' EXIT

run_medusa() {
    local status=0
    { medusa --without-log-timestamp "$@" 2>&1 1>&3 3>&- | tee -a "$log" >&2 3>&-; } 3>&1 || status=$?
    return "$status"
}

logged() {
    grep -Fq -- "$1" "$log"
}

case "$operation" in
    list-backups)
        if [ "$1" = true ]; then
            run_medusa list-backups --show-all
        else
            run_medusa list-backups
        fi
        ;;
    status)
        run_medusa status --backup-name "$1"
        ;;
    verify)
        if [ "$2" = true ]; then
            run_medusa verify --backup-name "$1" --enable-md5-checks
        else
            run_medusa verify --backup-name "$1"
        fi
        ;;
    last-complete)
        run_medusa get-last-complete-cluster-backup
        ;;
    tokenmap)
        run_medusa fetch-tokenmap --backup-name "$1"
        ;;
    report-last)
        run_medusa report-last-backup
        if logged 'This error happened during the check'; then
            echo "Medusa could not produce the report; its error is in the log above." >&2
            exit 1
        fi
        ;;
    backup)
        name=$1
        flags=(--backup-name "$name" --mode "$2")
        if [ "$3" = true ]; then
            flags+=(--enable-md5-checks)
        fi
        run_medusa backup-node "${flags[@]}"
        # Medusa logs a failed nodetool snapshot, then uploads whatever the
        # snapshot reached, often nothing, and marks that backup the latest.
        if logged 'Creating snapshot failed'; then
            echo "The nodetool snapshot failed, so backup $name is missing data. Remove it with medusa.delete_backup before reusing the name." >&2
            exit 1
        fi
        files=$(sed -n 's/^INFO: - \([0-9][0-9]*\) files, .*/\1/p' "$log" | tail -n 1)
        if [ -z "$files" ] || [ "$files" -eq 0 ]; then
            echo "Backup $name finished without recording any files. Remove it with medusa.delete_backup before reusing the name." >&2
            exit 1
        fi
        ;;
    purge)
        run_medusa purge
        ;;
    delete)
        run_medusa delete-backup --backup-name "$1" "--$2"
        ;;
    restore)
        name=$1
        # Medusa stops Cassandra, then moves and chowns files in the data
        # directories. Refuse before it downloads or stops anything.
        if [ "$(id -u)" -ne 0 ]; then
            echo "Restoring needs the Emisar service to run as root (see this pack's host access). Nothing was downloaded and Cassandra is still running." >&2
            exit 1
        fi
        temp_dir=${MEDUSA_RESTORE_TEMP_DIR:-/tmp}
        if [ ! -d "$temp_dir" ]; then
            echo "MEDUSA_RESTORE_TEMP_DIR is not a directory: $temp_dir. Nothing was downloaded and Cassandra is still running." >&2
            exit 1
        fi
        flags=(--in-place --backup-name "$name" --temp-dir "$temp_dir")
        if [ "$2" = true ]; then
            flags+=(--verify)
        else
            flags+=(--no-verify)
        fi
        run_medusa restore-node "${flags[@]}"
        # An empty backup ends here with exit 0, before Cassandra is stopped.
        if logged 'There is nothing to restore'; then
            echo "Backup $name holds no data for this node, so nothing was restored. Cassandra was not stopped." >&2
            exit 1
        fi
        ;;
    *)
        echo "Unknown operation: $operation" >&2
        exit 2
        ;;
esac
