#!/usr/bin/env bash
# Read-only process ancestry and descendants without printing command-line args.

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

ps -eo pid=,ppid=,user=,etime=,pcpu=,pmem=,comm= |
  awk -v root="$pid" '
    {
      pid=$1
      ppid=$2
      user=$3
      etime=$4
      cpu=$5
      mem=$6
      $1=$2=$3=$4=$5=$6=""
      sub(/^ +/, "")
      comm=$0
      parent[pid]=ppid
      children[ppid]=children[ppid] " " pid
      line[pid]=sprintf("%8s %8s %-16s %12s %6s %6s %s", pid, ppid, user, etime, cpu, mem, comm)
    }

    function print_header() {
      printf "%8s %8s %-16s %12s %6s %6s %s\n", "PID", "PPID", "USER", "ELAPSED", "%CPU", "%MEM", "COMM"
    }

    function print_ancestors(pid, current, depth) {
      current = pid
      depth = 0
      while (current in line && depth < 64) {
        stack[++depth] = current
        if (!(current in parent) || parent[current] == current || parent[current] == 0) {
          break
        }
        current = parent[current]
      }
      for (i = depth; i >= 1; i--) {
        print line[stack[i]]
      }
    }

    function print_tree(pid, depth, parts, count, i, child, prefix) {
      if (!(pid in line) || seen[pid]) {
        return
      }
      seen[pid] = 1
      prefix = ""
      for (i = 0; i < depth; i++) {
        prefix = prefix "  "
      }
      print prefix line[pid]
      count = split(children[pid], parts, " ")
      for (i = 1; i <= count; i++) {
        child = parts[i]
        if (child != "") {
          print_tree(child, depth + 1)
        }
      }
    }

    END {
      if (!(root in line)) {
        printf "no such process: %s\n", root > "/dev/stderr"
        exit 3
      }

      print "== ancestors =="
      print_header()
      print_ancestors(root)

      print ""
      print "== descendants =="
      print_header()
      print_tree(root, 0)
    }
  '
