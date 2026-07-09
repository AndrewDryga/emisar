#!/usr/bin/env bash
# Read-only Linux /proc summary for a BEAM process.

set -euo pipefail

pid=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid)
      pid="$2"
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! "$pid" =~ ^[0-9]+$ ]] || ((pid < 1 || pid > 4194304)); then
  echo "invalid pid: ${pid}" >&2
  exit 2
fi

proc="/proc/${pid}"
if [[ ! -d "$proc" ]]; then
  echo "no such process: ${pid}" >&2
  exit 3
fi

echo "== status =="
awk '/^(Name|State|Pid|PPid|Uid|Gid|VmPeak|VmSize|VmRSS|VmData|VmStk|VmExe|VmLib|VmSwap|Threads|FDSize|voluntary_ctxt_switches|nonvoluntary_ctxt_switches):/ { print }' "${proc}/status"

echo
echo "== statm =="
if [[ -r "${proc}/statm" ]]; then
  awk '{ print "size_pages: " $1 "\nresident_pages: " $2 "\nshared_pages: " $3 "\ntext_pages: " $4 "\ndata_stack_pages: " $6 }' "${proc}/statm"
else
  echo "(not readable)"
fi

echo
echo "== smaps_rollup =="
if [[ -r "${proc}/smaps_rollup" ]]; then
  awk '/^(Rss|Pss|Pss_Anon|Pss_File|Pss_Shmem|Shared_Clean|Shared_Dirty|Private_Clean|Private_Dirty|Referenced|Anonymous|LazyFree|AnonHugePages|ShmemPmdMapped|FilePmdMapped|Shared_Hugetlb|Private_Hugetlb|Swap|SwapPss|Locked):/ { print }' "${proc}/smaps_rollup"
else
  echo "(not available or not readable)"
fi

echo
echo "== counts =="
fd_count="unreadable"
if [[ -d "${proc}/fd" ]]; then
  fd_count="$(find "${proc}/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
fi

thread_count="unreadable"
if [[ -d "${proc}/task" ]]; then
  thread_count="$(find "${proc}/task" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
fi

map_count="unreadable"
if [[ -r "${proc}/maps" ]]; then
  map_count="$(wc -l < "${proc}/maps" | tr -d ' ')"
fi

printf 'fd_count: %s\n' "$fd_count"
printf 'thread_count: %s\n' "$thread_count"
printf 'memory_map_count: %s\n' "$map_count"
