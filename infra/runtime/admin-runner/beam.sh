#!/bin/sh
set -eu

tool=${0##*/}

unsupported() {
  echo "unsupported emisar admin BEAM bridge invocation" >&2
  exit 2
}

case "$tool" in
  elixir)
    [ "$#" -eq 1 ] && [ "$1" = "--version" ] || unsupported
    exec docker exec emisar /app/bin/emisar rpc \
      'otp = :erlang.system_info(:otp_release) |> List.to_string(); erts = :erlang.system_info(:version) |> List.to_string(); build = System.build_info(); IO.puts("Erlang/OTP #{otp} [erts-#{erts}]"); IO.puts("Elixir #{build.build}")'
    ;;
  erl)
    [ "$#" -eq 3 ] && [ "$1" = "-noshell" ] && [ "$2" = "-eval" ] && \
      [ "$3" = 'io:format("~s~n", [erlang:system_info(system_version)]), halt().' ] || unsupported
    exec docker exec emisar /app/bin/emisar rpc \
      'IO.puts(:erlang.system_info(:system_version) |> List.to_string())'
    ;;
  epmd)
    [ "$#" -eq 1 ] && [ "$1" = "-names" ] || unsupported
    exec docker exec emisar /app/bin/emisar rpc \
      'case :erl_epmd.names() do {:ok, names} -> IO.puts("epmd: up and running on port 4369 with data:"); Enum.each(names, fn {name, port} -> IO.puts("name #{List.to_string(name)} at port #{port}") end); {:error, reason} -> raise "epmd query failed: #{inspect(reason)}" end'
    ;;
  *)
    unsupported
    ;;
esac
