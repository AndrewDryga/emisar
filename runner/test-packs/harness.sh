#!/usr/bin/env bash
# Run every action in a pack's test/cases.yaml.
# Usage: harness.sh <pack-name>
# Reads cases from /packs/<pack>/test/cases.yaml
# Exit 0 if every case passes, 1 otherwise.
#
# cases.yaml schema:
#   defaults:
#     env:
#       KEY: value         # set before every run
#   cases:
#     - action: redis.info
#       args: {key: value} # passed as --arg key=value
#       expect_exit: 0     # or [0, 1] (any of)
#       expect_stdout_contains: ["redis_version"]
#       expect_stderr_contains: []
#       reason: smoke      # optional, recorded by emisar
#       skip: "needs N-replica cluster"  # if set, skips with WARN

set -uo pipefail

PACK="${1:?usage: harness.sh <pack-name>}"
EMISAR="${EMISAR:-/opt/emisar/bin/emisar}"
PACK_DIR="${PACK_DIR:-/packs}"
CASES_FILE="$PACK_DIR/$PACK/test/cases.yaml"

if [ ! -f "$CASES_FILE" ]; then
    echo "no cases file: $CASES_FILE"
    exit 2
fi

# Pull defaults.env keys then for each case run emisar action run.
# Uses yq to parse YAML. If yq missing, install or fail loud.
if ! command -v yq >/dev/null 2>&1; then
    echo "yq not installed in runner-tools image; can't parse cases"
    exit 3
fi

# Export defaults.env to current shell
while IFS='=' read -r k v; do
    [ -n "$k" ] && export "$k=$v"
done < <(yq -r '.defaults.env // {} | to_entries[] | "\(.key)=\(.value)"' "$CASES_FILE")

PASS=0
FAIL=0
SKIP=0
N=$(yq -r '.cases | length' "$CASES_FILE")

for i in $(seq 0 $((N-1))); do
    action=$(yq -r ".cases[$i].action" "$CASES_FILE")
    skip=$(yq -r ".cases[$i].skip // empty" "$CASES_FILE")
    if [ -n "$skip" ]; then
        echo "SKIP $action — $skip"
        SKIP=$((SKIP+1))
        continue
    fi

    # Collect --arg key=value flags
    mapfile -t args < <(yq -r ".cases[$i].args // {} | to_entries[] | \"--arg\\n\(.key)=\(.value)\"" "$CASES_FILE")
    reason=$(yq -r ".cases[$i].reason // \"smoke\"" "$CASES_FILE")
    expect_exit=$(yq -r ".cases[$i].expect_exit // 0" "$CASES_FILE")

    stdout=$(mktemp); stderr=$(mktemp)
    "$EMISAR" action run "$action" "${args[@]}" --reason "$reason" --stream >"$stdout" 2>"$stderr"
    actual_exit=$?

    # exit-code match: either scalar or array of allowed values
    if [[ "$expect_exit" =~ ^\[ ]]; then
        mapfile -t allowed < <(yq -r ".cases[$i].expect_exit[]" "$CASES_FILE")
        ok=0
        for a in "${allowed[@]}"; do [ "$a" = "$actual_exit" ] && ok=1; done
    else
        ok=$([ "$actual_exit" = "$expect_exit" ] && echo 1 || echo 0)
    fi

    # stdout/stderr substring checks
    while IFS= read -r needle; do
        [ -z "$needle" ] && continue
        if ! grep -qF -- "$needle" "$stdout"; then ok=0; fi
    done < <(yq -r ".cases[$i].expect_stdout_contains // [] | .[]" "$CASES_FILE")
    while IFS= read -r needle; do
        [ -z "$needle" ] && continue
        if ! grep -qF -- "$needle" "$stderr"; then ok=0; fi
    done < <(yq -r ".cases[$i].expect_stderr_contains // [] | .[]" "$CASES_FILE")

    if [ "$ok" = "1" ]; then
        echo "PASS $action  (exit=$actual_exit)"
        PASS=$((PASS+1))
    else
        echo "FAIL $action  (exit=$actual_exit, expected=$expect_exit)"
        echo "  --- stdout ---"; sed 's/^/  /' "$stdout"
        echo "  --- stderr ---"; sed 's/^/  /' "$stderr"
        FAIL=$((FAIL+1))
    fi
    rm -f "$stdout" "$stderr"
done

echo
echo "[$PACK] pass=$PASS fail=$FAIL skip=$SKIP total=$N"
[ "$FAIL" -eq 0 ]
