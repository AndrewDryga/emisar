#!/usr/bin/env bash
# Run harness.sh against every pack that has a test/cases.yaml.
# Usage: run-all.sh [pack-name-pattern]
#
# Spawns the SUT(s) declared in cases.yaml, runs the pack, tears them down.
# Prints per-pack summary then a grand-total.
set -uo pipefail

PATTERN="${1:-}"
PACK_ROOT="${PACK_ROOT:-/packs}"
HERE="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$HERE/harness.sh"
REPORT_DIR="${REPORT_DIR:-/reports}"
mkdir -p "$REPORT_DIR"

TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0; PACKS_RUN=0; PACKS_FAILED=0

for cases in "$PACK_ROOT"/*/test/cases.yaml; do
    [ -f "$cases" ] || continue
    pack=$(basename "$(dirname "$(dirname "$cases")")")
    [ -n "$PATTERN" ] && [[ "$pack" != *"$PATTERN"* ]] && continue

    echo "================================"
    echo "Pack: $pack"
    echo "================================"

    log="$REPORT_DIR/$pack.log"
    "$HARNESS" "$pack" 2>&1 | tee "$log"
    rc=$?

    # Pull totals from the tail line
    line=$(grep -E "^\[$pack\] pass=" "$log" | tail -1)
    p=$(echo "$line" | sed -E 's/.*pass=([0-9]+).*/\1/')
    f=$(echo "$line" | sed -E 's/.*fail=([0-9]+).*/\1/')
    s=$(echo "$line" | sed -E 's/.*skip=([0-9]+).*/\1/')
    TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
    TOTAL_FAIL=$((TOTAL_FAIL + ${f:-0}))
    TOTAL_SKIP=$((TOTAL_SKIP + ${s:-0}))
    PACKS_RUN=$((PACKS_RUN+1))
    [ "$rc" -ne 0 ] && PACKS_FAILED=$((PACKS_FAILED+1))
done

echo
echo "==============================="
echo "GRAND TOTAL"
echo "==============================="
echo "Packs run:     $PACKS_RUN"
echo "Packs failed:  $PACKS_FAILED"
echo "Tests passed:  $TOTAL_PASS"
echo "Tests failed:  $TOTAL_FAIL"
echo "Tests skipped: $TOTAL_SKIP"

[ "$TOTAL_FAIL" -eq 0 ] && [ "$PACKS_FAILED" -eq 0 ]
