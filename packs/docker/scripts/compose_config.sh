#!/bin/bash
set -euo pipefail

file=$1
readonly max_section_bytes=65536
# The reader below ends every capture with this byte and bounded_section strips
# it again. It exists because command substitution strips TRAILING NEWLINES:
# without a non-newline byte at the end, a 65,537-byte section whose last byte
# is a newline arrives as 65,536 and passes the bound it just broke. A control
# byte is used because no Compose name ends in one, and the summary below
# collapses controls anyway if one ever did.
readonly capture_sentinel=$'\x1f'

compose_config() {
  docker compose -f "$file" --profile '*' config \
    --no-interpolate --no-env-resolution "$@"
}

compose_config_json() {
  compose_config --no-normalize --format json
}

# Keep one byte past the bound and throw the rest away, so what this script
# holds per section is fixed whatever the operator's file produces. Capturing a
# section whole instead makes `docker compose config` on a large stack the size
# of this shell's heap: a 256 MiB service section ends the action on bash's own
# `xrealloc: cannot allocate` rather than the authored message below.
#
# `cat >/dev/null` is the load-bearing half. `head -c` on its own closes the
# pipe at its limit and SIGPIPEs the producer, which `pipefail` then reports as
# a failed run of a parse that in fact succeeded — the bare 141 this action was
# filed for. Draining lets the producer reach its own exit, so the status the
# pipeline returns is the producer's real one. `head -c` passes on no more than
# it is asked for, and whatever it read beyond the bound is over the bound
# anyway, so the drain's completeness only has to keep the producer writing.
retain_bounded_section() {
  head -c "$((max_section_bytes + 1))"
  cat >/dev/null
  printf '%s' "$capture_sentinel"
}

# The size is measured in BYTES, by `wc -c`, because the bound is bytes.
# `${#value}` counts CHARACTERS, so under any UTF-8 locale a section of
# multibyte names passes a bound it exceeds by up to four times.
bounded_section() {
  local captured=$1
  local value=${captured%"$capture_sentinel"}
  # The marker is retain_bounded_section's half of the contract; without it the
  # measurement below is off by whatever the capture lost, so refuse instead.
  [ "$value" != "$captured" ] || {
    printf '%s\n' "Compose config summary section lost its capture marker" >&2
    exit 1
  }
  local bytes
  bytes=$(printf '%s' "$value" | wc -c) || exit $?
  ((bytes <= max_section_bytes)) || {
    printf '%s\n' "Compose config summary section exceeded 64 KiB" >&2
    exit 1
  }
  printf '%s' "$value"
}

# Each helper below takes its whole pipeline's status in place with `|| exit $?`.
#
# `set -e` is NOT inherited into a command substitution — and every call here is
# one, `services=$(bounded_list --services)` — so a bare assignment leaves a
# failed `docker compose config` discarded mid-function: the section is empty,
# it passes the size check, and the action reports `valid: true` with an empty
# list and exit 0. That is the false all-clear
# `.agent/kb/rules/packs-pipelines-fail-on-source-errors.md` is about, on a read
# an operator uses to decide whether a stack parses. With `pipefail`, the same
# `|| exit $?` also carries a failure of `jq` or of the reader itself.
bounded_list() {
  local captured
  captured=$(compose_config "$1" | retain_bounded_section) || exit $?
  bounded_section "$captured"
}

bounded_json_list() {
  local filter=$1
  local captured
  captured=$(compose_config_json | jq -r "$filter" | retain_bounded_section) || exit $?
  bounded_section "$captured"
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
