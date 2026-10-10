#!/usr/bin/env bash
set -euo pipefail

fixture_dir=/tmp/packtest/cassandra-client
fifo="$fixture_dir/input"
pid_file="$fixture_dir/client.pid"

owned_client() {
  [[ -f "$pid_file" ]] || return 1
  read -r client_pid < "$pid_file"
  [[ "$client_pid" =~ ^[0-9]+$ ]] || return 1
  [[ "$(readlink "/proc/$client_pid/fd/0" 2>/dev/null || true)" == "$fifo" ]]
}

case "${1-}" in
  start)
    umask 077
    mkdir -m 700 "$fixture_dir"
    mkfifo "$fifo"
    # Keep the FIFO open in both directions so cqlsh stays signed in between
    # harness steps. Authentication stays in the private fixture credentials.
    nohup sh -c 'exec 3<>"$1"; exec cqlsh --cqlshrc /tmp/packtest/.cassandra/cqlshrc --disable-history -k packtest 127.0.0.1 9042 <&3' sh "$fifo" \
      </dev/null >"$fixture_dir/client.log" 2>&1 &
    printf '%s\n' "$!" > "$pid_file"
    ;;
  check)
    owned_client || exit 1
    output=$(nodetool clientstats --all) || exit "$?"
    printf '%s\n' "$output" | awk '
      $1 ~ /^\/?127\.0\.0\.1:[0-9]+$/ && $6 == "cassandra" && $7 == "packtest" && $(NF-3) == "DataStax" && $(NF-2) == "Python" && $(NF-1) == "Driver" && $NF ~ /^[0-9]/ { found = 1 }
      END { exit !found }
    '
    printf 'authenticated client has address, user, keyspace and driver version\n'
    ;;
  stop)
    if owned_client; then
      # RDWR never blocks if the client exited between the ownership check
      # and this write; only this case-owned FIFO/PID can be signalled.
      exec 3<>"$fifo"
      printf 'EXIT;\n' >&3
      exec 3>&-
      for _ in 1 2 3 4 5; do
        owned_client || break
        sleep 1
      done
      if owned_client; then kill -TERM "$client_pid"; fi
    fi
    rm -f -- "$fifo" "$pid_file" "$fixture_dir/client.log"
    rmdir "$fixture_dir"
    ;;
  *) printf 'expected start, check or stop\n' >&2; exit 2 ;;
esac
