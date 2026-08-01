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

bounded_list() {
  local value
  value=$(compose_config "$1" | head -c "$((max_section_bytes + 1))")
  ((${#value} <= max_section_bytes)) || {
    printf '%s\n' "Compose config summary section exceeded 64 KiB" >&2
    exit 1
  }
  printf '%s' "$value"
}

bounded_json_list() {
  local filter=$1
  local value
  value=$(compose_config_json | jq -r "$filter" |
    head -c "$((max_section_bytes + 1))")
  ((${#value} <= max_section_bytes)) || {
    printf '%s\n' "Compose config summary section exceeded 64 KiB" >&2
    exit 1
  }
  printf '%s' "$value"
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
COMPOSE_FILE=$file \
  COMPOSE_SERVICES=$services \
  COMPOSE_IMAGES=$images \
  COMPOSE_NETWORKS=$networks \
  COMPOSE_VOLUMES=$volumes \
  COMPOSE_PROFILES=$profiles \
  jq -nce '
    def lines($name):
      env[$name] | split("\n") | map(select(length > 0)) | unique | sort;
    def clipped($chars; $bytes):
      (tostring | gsub("[[:cntrl:]]+"; " ")) as $clean
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
