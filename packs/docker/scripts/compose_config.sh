#!/bin/bash
set -euo pipefail

file=$1
readonly max_section_bytes=65536

compose_config() {
  docker compose -f "$file" --profile '*' config \
    --no-interpolate --no-env-resolution "$@"
}

compose_config_json() {
  compose_config --no-normalize --format json
}

bounded_section() {
  local value=$1
  ((${#value} <= max_section_bytes)) || {
    printf '%s\n' "Compose config summary section exceeded 64 KiB" >&2
    exit 1
  }
  printf '%s' "$value"
}

# Each helper below captures its section whole and takes the source's status with
# `|| exit $?`. Both halves are load-bearing.
#
# `set -e` is NOT inherited into a command substitution — and every call here is
# one, `services=$(bounded_list --services)` — so a bare assignment leaves a
# failed `docker compose config` discarded mid-function: the section is empty,
# it passes the size check, and the action reports `valid: true` with an empty
# list and exit 0. That is the false all-clear
# `.agent/kb/rules/packs-pipelines-fail-on-source-errors.md` is about, on a read
# an operator uses to decide whether a stack parses.
#
# And no `head -c`: it exits at its limit and SIGPIPEs the producer, which
# `pipefail` reports as a failed run of a successful parse, and it clips the
# value to one byte past the bound, so the check above could only ever see that
# clip rather than the section's real size.
bounded_list() {
  local value
  value=$(compose_config "$1") || exit $?
  bounded_section "$value"
}

bounded_json_list() {
  local filter=$1
  local value
  value=$(compose_config_json | jq -r "$filter") || exit $?
  bounded_section "$value"
}

# Parse the complete file first, without resolving environment or interpolation.
compose_config --quiet

services=$(bounded_list --services)
networks=$(bounded_list --networks)
volumes=$(bounded_list --volumes)
images=$(bounded_json_list \
  '[.services[]?.image? | select(type == "string" and length > 0)] | unique[]')
profiles=$(bounded_json_list \
  '[.services[]?.profiles[]? | select(type == "string" and length > 0)] | unique[]')

# Each list is a capped, clipped sample with an explicit omitted count: the
# runner rejects a structured result over 8 KiB, so an unbounded stack summary
# would deterministically fail on exactly the stacks worth summarizing. The
# caps and clips are sized so all lists at their worst escaped case stay well
# under the cap.
#
# controls_collapsed is the clip's cleanup on core jq. The obvious spelling,
# gsub("[[:cntrl:]]+"; " "), needs Oniguruma, which jq's own supported
# --with-oniguruma=no build omits: there the call raises "jq was compiled
# without ONIGURUMA regex library" the first time it runs, so this summary
# fails on that host and nowhere else. The class Oniguruma matched is exactly
# Unicode Cc, U+0000–U+001F and U+007F–U+009F, so each of those codepoints
# becomes 0 — itself a control, so no ordinary character collides with the
# marker — a run keeps only its first, and the survivor becomes a space. A
# space already in the text is left alone.
COMPOSE_FILE=$file \
  COMPOSE_SERVICES=$services \
  COMPOSE_IMAGES=$images \
  COMPOSE_NETWORKS=$networks \
  COMPOSE_VOLUMES=$volumes \
  COMPOSE_PROFILES=$profiles \
  jq -nce '
    def lines($name):
      env[$name] | split("\n") | map(select(length > 0)) | unique | sort;
    def controls_collapsed:
      (explode | map(if . <= 31 or (. >= 127 and . <= 159) then 0 else . end)) as $cs
      | [range($cs | length) | select(. == 0 or $cs[.] != 0 or $cs[. - 1] != 0) | $cs[.]]
      | map(if . == 0 then 32 else . end)
      | implode;
    def clipped($chars; $bytes):
      (tostring | controls_collapsed) as $clean
      | ($clean | .[:$chars] | until(utf8bytelength <= $bytes; .[:-1])) as $cut
      | if $cut == $clean then $clean else ($cut | .[:$chars - 1]) + "…" end;
    def capped($names; $cap; $size):
      {sample: ($names | .[:$cap] | map(clipped($size; $size))),
       omitted: (($names | length) - ($names | .[:$cap] | length))};
    (capped(lines("COMPOSE_SERVICES"); 24; 48)) as $services |
    (capped(lines("COMPOSE_IMAGES"); 12; 96)) as $images |
    (capped(lines("COMPOSE_NETWORKS"); 8; 48)) as $networks |
    (capped(lines("COMPOSE_VOLUMES"); 8; 48)) as $volumes |
    (capped(lines("COMPOSE_PROFILES"); 6; 32)) as $profiles |
    {
      valid: true,
      file: env.COMPOSE_FILE,
      services: $services.sample,
      images: $images.sample,
      networks: $networks.sample,
      volumes: $volumes.sample,
      profiles: $profiles.sample,
      truncated: {
        services: $services.omitted,
        images: $images.omitted,
        networks: $networks.omitted,
        volumes: $volumes.omitted,
        profiles: $profiles.omitted
      }
    }
  '
