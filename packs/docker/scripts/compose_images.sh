#!/bin/bash
set -euo pipefail

file=$1
readonly max_output_bytes=524288
# The reader below ends every capture with this byte and the measurement strips
# it again. It exists because command substitution strips TRAILING NEWLINES:
# `docker compose images --format json` ends its document with one, so without a
# non-newline byte after it a 524,289-byte inventory arrives as 524,288 and
# passes the bound it just broke. A control byte is used because this producer
# emits JSON, where a raw control byte is not legal in a string anyway.
readonly capture_sentinel=$'\x1f'

# `cat >/dev/null` is the load-bearing half. `head -c` on its own closes the pipe
# at its limit and SIGPIPEs `docker`, which `pipefail` reports as 141 — and
# `set -e` then ends the script AT the assignment below, so the authored refusal
# never runs and the action answers an over-bound inventory with a bare 141 and
# no explanation, on a `low`, no-approval read. Draining lets the producer reach
# its own exit, so the status the pipeline carries is the producer's real one.
# `head -c` passes on no more than it is asked for, and whatever it read beyond
# the bound is over the bound anyway, so the drain only has to keep the producer
# writing.
#
# The readers' OWN failures have to be carried by hand: `set -e` does not reach
# into a command substitution, and a `printf` returning 0 last would make this
# function 0 whatever `head` and `cat` did — the pipeline would then report the
# producer's 0 and the sentinel would mark an EMPTY capture as a complete
# inventory, which projects as `[]`: "this project has created no containers".
# So both statuses are saved and returned, and the sentinel is emitted only once
# both halves have succeeded. The drain runs even after the reader failed, so a
# failing `head` does not also SIGPIPE the producer into a status that would
# bury the real one. Same shape, same reasoning, as compose_config.sh's
# retain_bounded_section.
retain_bounded_inventory() {
  local read_status=0
  local drain_status=0
  head -c "$((max_output_bytes + 1))" || read_status=$?
  cat >/dev/null || drain_status=$?
  ((read_status == 0)) || return "$read_status"
  ((drain_status == 0)) || return "$drain_status"
  printf '%s' "$capture_sentinel"
}

# `|| exit $?` rather than relying on `set -e`: the capture runs through a
# command substitution, so this is where a failed `docker compose images` — or a
# failed reader, which only reaches here because the function returned its
# status by hand — has to be taken.
captured=$(docker compose -f "$file" images --format json |
  retain_bounded_inventory) || exit $?
images=${captured%"$capture_sentinel"}
# The marker is retain_bounded_inventory's half of the contract; without it the
# measurement below is off by whatever the capture lost, so refuse instead.
[[ "$images" != "$captured" ]] || {
  printf '%s\n' "Compose image inventory lost its capture marker" >&2
  exit 1
}

# The size is measured in BYTES, by `wc -c`, because the bound is bytes.
# `${#images}` counts CHARACTERS, so under any UTF-8 locale an inventory of
# multibyte repository names passes a bound it exceeds by up to four times.
bytes=$(printf '%s' "$images" | wc -c) || exit $?
((bytes <= max_output_bytes)) || {
  printf '%s\n' "Compose image inventory exceeded 512 KiB" >&2
  exit 1
}

if [[ -z "$images" ]]; then
  printf '[]\n'
else
  jq -ce '
    if . == null then []
    elif type == "array" then .
    else error("unexpected Compose image output")
    end
  ' \
    <<<"$images"
fi
