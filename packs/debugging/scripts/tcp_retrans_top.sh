#!/bin/sh
set -eu

inventory=$(LC_ALL=C ss -H -tnpi state established) || exit $?
rows=$(printf '%s\n' "$inventory" | awk '
  function emit() {
    if (total > 0)
      printf "%.0f\t%.0f\t%s\t%s\t%s\n", total, current, local, peer, process
  }
  # A single selected state suppresses ss State: queues, local, peer, process.
  $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && NF >= 4 {
    emit()
    local = $3
    peer = $4
    process = ""
    for (i = 5; i <= NF; i++)
      process = process (i == 5 ? "" : " ") $i
    total = current = 0
    next
  }
  local != "" {
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^retrans:[0-9]+\/[0-9]+$/) {
        split(substr($i, 9), counters, "/")
        current = counters[1] + 0
        total = counters[2] + 0
      }
    }
  }
  END { emit() }
') || exit $?
sorted=$(printf '%s\n' "$rows" | LC_ALL=C sort -k1,1nr -k3,3 -k4,4) || exit $?
printf 'total_retrans\tcurrent_retrans\tlocal\tpeer\tprocess\n'
printf '%s\n' "$sorted" | awk 'NF && NR <= 50'
