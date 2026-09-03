#!/bin/sh
set -eu

[ "$#" -ge 1 ] || { echo "missing admin action id" >&2; exit 2; }
action_id=$1
shift

encode() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

encoded_args=
separator=
arg_count=0
for arg in "$@"; do
  arg_count=$((arg_count + 1))
  encoded_args="${encoded_args}${separator}\"$(encode "$arg")\""
  separator=", "
done

[ "$arg_count" -le 3 ] || { echo "too many admin action arguments" >&2; exit 2; }

encoded_action_id=$(encode "$action_id")

expression="action_id = Base.decode64!(\"$encoded_action_id\"); args = Enum.map([$encoded_args], &Base.decode64!/1); case Emisar.Admin.execute(action_id, args) do {:ok, result} -> IO.puts(\"__EMISAR_ADMIN_OK__\" <> Jason.encode!(%{ok: true, result: result})); {:error, reason} -> IO.puts(\"__EMISAR_ADMIN_ERROR__\" <> Jason.encode!(%{ok: false, error: inspect(reason, limit: 20, printable_limit: 1000)})) end"

if ! output=$(docker exec emisar /app/bin/emisar rpc "$expression"); then
  echo "portal release RPC failed" >&2
  exit 1
fi

case "$output" in
  __EMISAR_ADMIN_OK__*) printf '%s\n' "${output#__EMISAR_ADMIN_OK__}" ;;
  __EMISAR_ADMIN_ERROR__*) printf '%s\n' "${output#__EMISAR_ADMIN_ERROR__}" >&2; exit 1 ;;
  *) echo "portal release RPC returned an invalid response" >&2; exit 1 ;;
esac
