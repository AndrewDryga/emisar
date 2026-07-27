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

COMPOSE_FILE=$file \
  COMPOSE_SERVICES=$services \
  COMPOSE_IMAGES=$images \
  COMPOSE_NETWORKS=$networks \
  COMPOSE_VOLUMES=$volumes \
  COMPOSE_PROFILES=$profiles \
  jq -nce '
    def lines($name):
      env[$name] | split("\n") | map(select(length > 0)) | unique | sort;
    {
      valid: true,
      file: env.COMPOSE_FILE,
      services: lines("COMPOSE_SERVICES"),
      images: lines("COMPOSE_IMAGES"),
      networks: lines("COMPOSE_NETWORKS"),
      volumes: lines("COMPOSE_VOLUMES"),
      profiles: lines("COMPOSE_PROFILES")
    }
  '
