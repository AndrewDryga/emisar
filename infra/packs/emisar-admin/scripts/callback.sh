#!/bin/sh
set -eu

[ "$#" -ge 1 ] || { echo "missing admin action id" >&2; exit 2; }
action_id=$1
shift

[ "$#" -le 3 ] || { echo "too many admin action arguments" >&2; exit 2; }

arg_count=$#
arg_1=${1-}
arg_2=${2-}
arg_3=${3-}
expression='action_id = System.fetch_env!("EMISAR_ADMIN_ACTION_ID"); count = String.to_integer(System.fetch_env!("EMISAR_ADMIN_ARG_COUNT")); args = [System.get_env("EMISAR_ADMIN_ARG_1"), System.get_env("EMISAR_ADMIN_ARG_2"), System.get_env("EMISAR_ADMIN_ARG_3")] |> Enum.take(count); case Emisar.Admin.execute(action_id, args) do {:ok, result} -> IO.puts("__EMISAR_ADMIN_OK__" <> Jason.encode!(%{ok: true, result: result})); {:error, reason} -> IO.puts("__EMISAR_ADMIN_ERROR__" <> Jason.encode!(%{ok: false, error: inspect(reason, limit: 20, printable_limit: 1000)})) end'

if ! output=$(docker exec \
  --env "EMISAR_ADMIN_ACTION_ID=$action_id" \
  --env "EMISAR_ADMIN_ARG_COUNT=$arg_count" \
  --env "EMISAR_ADMIN_ARG_1=$arg_1" \
  --env "EMISAR_ADMIN_ARG_2=$arg_2" \
  --env "EMISAR_ADMIN_ARG_3=$arg_3" \
  emisar /app/bin/emisar rpc "$expression"); then
  echo "portal release RPC failed" >&2
  exit 1
fi

case "$output" in
  __EMISAR_ADMIN_OK__*) printf '%s\n' "${output#__EMISAR_ADMIN_OK__}" ;;
  __EMISAR_ADMIN_ERROR__*) printf '%s\n' "${output#__EMISAR_ADMIN_ERROR__}" >&2; exit 1 ;;
  *) echo "portal release RPC returned an invalid response" >&2; exit 1 ;;
esac
