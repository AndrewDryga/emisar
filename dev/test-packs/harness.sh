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
# `emisar action run` needs a config (packs dir + execution.inherit_env); without
# --config it falls back to /etc/emisar/config.yaml, which the image doesn't have.
CONFIG="${EMISAR_CONFIG:-/workspace/test-packs/test-config.yaml}"
CASES_FILE="$PACK_DIR/$PACK/test/cases.yaml"

# The emisar binary is mounted from the host at ./bin (git-ignored); the
# runner-tools image has no Go toolchain, so it must be cross-built on the HOST
# before `docker compose run`. Fail fast with the exact command rather than an
# obscure per-case exec error when it's absent.
if [ ! -x "$EMISAR" ]; then
    echo "emisar binary not found (or not executable) at: $EMISAR" >&2
    echo "Build it on the host first (LINUX binary matching the image arch):" >&2
    echo "    ( cd runner && GOOS=linux GOARCH=\"\$(go env GOARCH)\" go build -o ../dev/test-packs/bin/emisar . )" >&2
    exit 4
fi

if [ ! -f "$CASES_FILE" ]; then
    echo "no cases file: $CASES_FILE"
    exit 2
fi

# cases.yaml is parsed with jq, on JSON produced from the YAML by python3 — the
# expressions below are jq's (to_entries, \(...), // empty), and jq is the
# unambiguous, always-available tool in the image. (mikefarah yq speaks a
# different language and silently dropped skips/args.)
for tool in jq python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool not installed in runner-tools image; can't parse cases"
        exit 3
    fi
done

CASES_JSON=$(python3 -c 'import yaml, json, sys; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$CASES_FILE") || {
    echo "failed to parse $CASES_FILE as YAML"
    exit 3
}

# Export defaults.env to current shell
while IFS='=' read -r k v; do
    [ -n "$k" ] && export "$k=$v"
done < <(jq -r '.defaults.env // {} | to_entries[] | "\(.key)=\(.value)"' <<<"$CASES_JSON")

PASS=0
FAIL=0
SKIP=0
N=$(jq -r '.cases | length' <<<"$CASES_JSON")

for i in $(seq 0 $((N-1))); do
    action=$(jq -r ".cases[$i].action" <<<"$CASES_JSON")
    skip=$(jq -r ".cases[$i].skip // empty" <<<"$CASES_JSON")
    if [ -n "$skip" ]; then
        echo "SKIP $action — $skip"
        SKIP=$((SKIP+1))
        continue
    fi

    # Collect --arg key=value flags
    mapfile -t args < <(jq -r ".cases[$i].args // {} | to_entries[] | \"--arg\\n\(.key)=\(.value)\"" <<<"$CASES_JSON")
    reason=$(jq -r ".cases[$i].reason // \"smoke\"" <<<"$CASES_JSON")
    # -c so a list renders compact ([0,1]) for the ^\[ test below.
    expect_exit=$(jq -rc ".cases[$i].expect_exit // 0" <<<"$CASES_JSON")

    stdout=$(mktemp); stderr=$(mktemp)
    "$EMISAR" --config "$CONFIG" action run "$action" "${args[@]}" --reason "$reason" --stream >"$stdout" 2>"$stderr"
    actual_exit=$?

    # exit-code match: either scalar or array of allowed values
    if [[ "$expect_exit" =~ ^\[ ]]; then
        mapfile -t allowed < <(jq -r ".cases[$i].expect_exit[]" <<<"$CASES_JSON")
        ok=0
        for a in "${allowed[@]}"; do [ "$a" = "$actual_exit" ] && ok=1; done
    else
        ok=$([ "$actual_exit" = "$expect_exit" ] && echo 1 || echo 0)
    fi

    # stdout/stderr substring checks
    while IFS= read -r needle; do
        [ -z "$needle" ] && continue
        if ! grep -qF -- "$needle" "$stdout"; then ok=0; fi
    done < <(jq -r ".cases[$i].expect_stdout_contains // [] | .[]" <<<"$CASES_JSON")
    while IFS= read -r needle; do
        [ -z "$needle" ] && continue
        if ! grep -qF -- "$needle" "$stderr"; then ok=0; fi
    done < <(jq -r ".cases[$i].expect_stderr_contains // [] | .[]" <<<"$CASES_JSON")

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
