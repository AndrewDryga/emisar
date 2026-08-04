#!/bin/sh
# Stands in for the CLI via TF_BIN. A production-scale plan whose every field
# is hostile: 300 changes, addresses, types, modules, and reasons flooded with
# the byte JSON escaping doubles (backslash) and the codepoint whose escape
# costs six bytes (U+2028), more drift, outputs, and diagnostics than the
# bounded sample keeps. The worst-case behavior case projects this stream; the
# runner rejects a structured result over 8 KiB, so the case's success is the
# byte-cap proof. The two sentinel deletes sort first (uppercase sorts before
# a backslash) and pin the exact clip boundary: 80 characters survive intact,
# 81 clip to 79 plus an ellipsis; the AAC deletes keep U+2028 in the shown
# sample, not just in the dropped tail.

repeat() {
  i=0
  out=''
  while [ "$i" -lt "$2" ]; do
    out="$out$1"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

bs=$(repeat '\\' 100)
u2028=$(repeat "$(printf '\342\200\250')" 60)
sentinel_keep="AAA-sentinel-delete-$(repeat x 60)"
sentinel_clip="AAB-sentinel-delete-$(repeat x 61)"

change() {
  printf '{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"%s","module":"%s","resource_type":"%s","resource_name":"worst","resource_key":null},"action":"%s","reason":"%s"}}\n' \
    "$1" "module.$bs" "aws_$bs" "$2" "$3"
}

changes() {
  action=$1
  count=$2
  i=0
  while [ "$i" -lt "$count" ]; do
    change "$bs-$action-$(printf '%03d' "$i")" "$action" "$bs"
    i=$((i + 1))
  done
}

printf '{"@level":"info","@message":"Terraform 1.15.8","@module":"terraform.ui","terraform":"1.15.8-worst-case-build-with-a-very-long-version-string","type":"version","ui":"1.3"}\n'

change "$sentinel_keep" delete "$bs"
change "$sentinel_clip" delete "$bs"
i=0
while [ "$i" -lt 4 ]; do
  change "AAC-$(printf '%03d' "$i")-$u2028" delete "$bs"
  i=$((i + 1))
done
changes delete 114
changes replace 60
changes update 60
changes create 40
changes read 15
changes import 5
changes noop 10

i=0
while [ "$i" -lt 40 ]; do
  printf '{"@level":"info","@module":"terraform.ui","type":"resource_drift","change":{"resource":{"addr":"%s","module":"%s","resource_type":"%s","resource_name":"worst","resource_key":null},"action":"update"}}\n' \
    "$bs-drift-$(printf '%03d' "$i")" "module.$bs" "aws_$bs"
  i=$((i + 1))
done

outputs=''
i=0
while [ "$i" -lt 40 ]; do
  [ $((i % 2)) -eq 0 ] && sensitive=true || sensitive=false
  outputs="$outputs\"primary-database-connection-endpoint-$(printf '%03d' "$i")-$(repeat x 20)\":{\"sensitive\":$sensitive,\"action\":\"update\"},"
  i=$((i + 1))
done
i=0
while [ "$i" -lt 10 ]; do
  outputs="$outputs\"unchanged-output-$(printf '%03d' "$i")\":{\"sensitive\":false,\"action\":\"noop\"},"
  i=$((i + 1))
done
printf '{"@level":"info","@module":"terraform.ui","type":"outputs","outputs":{%s}}\n' "${outputs%,}"

# A diagnostic summary is CLI-authored free text, so it is where this stream
# carries the control bytes: ANSI colour, BEL, NUL, DEL and a C1 byte, written
# as the JSON \u escapes a real CLI emits. The projection collapses each run to
# one space, so no escape byte reaches the result.
diagnostic_summary="deprecated:\\u001b[33m attr\\u0007bell\\u0000null\\u007fdel\\u0085c1 usage detected in a module far away $(repeat 'and further away ' 6)"
i=0
while [ "$i" -lt 20 ]; do
  printf '{"@level":"warn","@module":"terraform.ui","type":"diagnostic","diagnostic":{"severity":"warning","summary":"%s"}}\n' "$diagnostic_summary"
  i=$((i + 1))
done

printf '{"@level":"info","@module":"terraform.ui","type":"change_summary","changes":{"add":40,"change":60,"import":5,"remove":120,"action_invocation":0,"operation":"plan"}}\n'
exit 0
