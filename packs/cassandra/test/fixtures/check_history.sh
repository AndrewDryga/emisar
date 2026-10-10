#!/usr/bin/env bash
set -euo pipefail
history=$(nodetool compactionhistory) || exit $?
printf '%s\n' "$history" | awk '
  NR > 2 && $2 == "packtest" && $3 == "history_new" { new_row = NR }
  NR > 2 && $2 == "packtest" && $3 == "history_old" { old_row = NR }
  END { exit !(new_row && old_row && new_row < old_row) }
'
printf 'two real compactions recorded, newest first\n'
