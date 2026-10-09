#!/bin/sh
set -eu

inventory=$(LC_ALL=C ss -H -tan) || exit $?
groups=$(printf '%s\n' "$inventory" | awk -v wanted="$1" '
  NF >= 5 {
    address = $5
    port = address
    sub(/^.*:/, "", port)
    sub(/:[^:]*$/, "", address)
    sub(/^\[/, "", address)
    # ss brackets the address before appending an optional %interface scope.
    sub(/\]/, "", address)
    if (wanted == "" || wanted == address)
      counts[$1 "\t" address "\t" port]++
  }
  END {
    for (key in counts)
      printf "%.0f\t%s\n", counts[key], key
  }
') || exit $?
sorted=$(printf '%s\n' "$groups" | LC_ALL=C sort -k1,1nr -k2,2 -k3,3 -k4,4) || exit $?
printf 'count\tstate\tpeer\tport\n'
printf '%s\n' "$sorted" | awk -v limit="$2" 'NF && NR <= limit'
