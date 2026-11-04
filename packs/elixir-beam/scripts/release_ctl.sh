#!/usr/bin/env bash
# Elixir release diagnostics through bin/RELEASE_NAME rpc.
#
# Targeting: the release to talk to is resolved per call, never supplied as
# an executable path by the caller. Precedence:
#   1. --release <name>  — discover running releases and pick by name;
#   2. ELIXIR_RELEASE_CTL — operator-pinned control-script path;
#   3. discovery         — exactly one running release, else a listing error.
# With --container <name> every step (discovery and the control script)
# runs inside that container via docker exec.
#
# Discovery only ever executes <root>/bin/<name> derived from the -boot flag
# of an already-running beam.smp process, so callers can select among live
# releases but cannot point the action at an arbitrary binary.

set -euo pipefail

mode=""
container=""
release=""
limit=25
sort_by=""
erlang_pid=""
registered_name=""
depth=2
sample_ms=1000
window_ms=0
samples=50
interval_ms=10
max_events=10000
trace_module=""
trace_function=""
trace_arity=""
max_traces=10
duration_ms=2000
pid_scope="all"
include_args="false"
include_return="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      mode="$2"
      shift 2
      ;;
    --container)
      container="$2"
      shift 2
      ;;
    --release)
      release="$2"
      shift 2
      ;;
    --limit)
      limit="$2"
      shift 2
      ;;
    --sort-by)
      sort_by="$2"
      shift 2
      ;;
    --erlang-pid)
      erlang_pid="$2"
      shift 2
      ;;
    --registered-name)
      registered_name="$2"
      shift 2
      ;;
    --depth)
      depth="$2"
      shift 2
      ;;
    --sample-ms)
      sample_ms="$2"
      shift 2
      ;;
    --window-ms)
      window_ms="$2"
      shift 2
      ;;
    --samples)
      samples="$2"
      shift 2
      ;;
    --interval-ms)
      interval_ms="$2"
      shift 2
      ;;
    --max-events)
      max_events="$2"
      shift 2
      ;;
    --module)
      trace_module="$2"
      shift 2
      ;;
    --function)
      trace_function="$2"
      shift 2
      ;;
    --arity)
      trace_arity="$2"
      shift 2
      ;;
    --max-traces)
      max_traces="$2"
      shift 2
      ;;
    --duration-ms)
      duration_ms="$2"
      shift 2
      ;;
    --pid-scope)
      pid_scope="$2"
      shift 2
      ;;
    --include-args)
      include_args="$2"
      shift 2
      ;;
    --include-return)
      include_return="$2"
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -n "$container" && ! "$container" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]; then
  echo "invalid container: ${container}" >&2
  exit 2
fi

if [[ -n "$release" && ! "$release" =~ ^[a-z][a-z0-9_]{0,63}$ ]]; then
  echo "invalid release: ${release}" >&2
  exit 2
fi

require_int() {
  local name="$1"
  local value="$2"
  local min="$3"
  local max="$4"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || ((value < min || value > max)); then
    echo "invalid ${name}: ${value}" >&2
    exit 2
  fi
}

require_bool() {
  local name="$1"
  local value="$2"
  case "$value" in
    true|false) ;;
    *)
      echo "invalid ${name}: ${value}" >&2
      exit 2
      ;;
  esac
}

# Takes a PID as the reads print it (#PID<0.123.0>) or bare (<0.123.0>), and
# leaves the bare form in erlang_pid.
require_erlang_pid() {
  if [[ ! "$erlang_pid" =~ ^(#PID)?\<[0-9]+\.[0-9]+\.[0-9]+\>$ ]]; then
    echo "invalid erlang_pid: ${erlang_pid}" >&2
    exit 2
  fi
  erlang_pid="${erlang_pid#\#PID}"
}

# POSIX-sh release scan: every running beam.smp started from a release has
# "-boot <root>/releases/<vsn>/start" in its argv; the <vsn> dir's .rel file
# names the release and <root>/bin/<name> is its control script. Runs under
# /bin/sh so the same text works on the host and inside any release
# container (a release needs /bin/sh to boot at all).
DISCOVER=$(cat <<'EOSH'
set -eu
for c in /proc/[0-9]*/comm; do
  [ -r "$c" ] || continue
  IFS= read -r comm < "$c" || continue
  case "$comm" in (beam.smp|beam) ;; (*) continue ;; esac
  pid=${c#/proc/}
  pid=${pid%/comm}
  boot=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | awk 'p == 1 { print; exit } $0 == "-boot" { p = 1 }')
  case "$boot" in (*/releases/*) ;; (*) continue ;; esac
  root=${boot%/releases/*}
  vsndir=${boot%/*}
  name=""
  for rel in "$vsndir"/*.rel; do
    [ -e "$rel" ] || continue
    base=${rel##*/}
    name=${base%.rel}
    break
  done
  [ -n "$name" ] || continue
  ctl="$root/bin/$name"
  [ -x "$ctl" ] || continue
  printf '%s\t%s\t%s\n' "$name" "$root" "$ctl"
done | sort -u
EOSH
)

discover() {
  if [[ -n "$container" ]]; then
    docker exec "$container" /bin/sh -c "$DISCOVER"
  else
    /bin/sh -c "$DISCOVER"
  fi
}

where() {
  if [[ -n "$container" ]]; then
    echo "container ${container}"
  else
    echo "this host"
  fi
}

release_ctl=""

resolve_ctl() {
  local rows

  if [[ -n "$release" ]]; then
    if ! rows=$(discover); then
      echo "failed to scan for releases in $(where)" >&2
      exit 3
    fi
    rows=$(awk -F'\t' -v n="$release" '$1 == n' <<<"$rows")
    if [[ -z "$rows" ]]; then
      echo "no running release named ${release} in $(where); run beam.release_targets to list targets" >&2
      exit 3
    fi
    if (($(wc -l <<<"$rows") > 1)); then
      echo "several releases named ${release} run in $(where); pin one with ELIXIR_RELEASE_CTL:" >&2
      echo "$rows" >&2
      exit 3
    fi
    release_ctl=$(cut -f3 <<<"$rows")
    return
  fi

  if [[ -n "${ELIXIR_RELEASE_CTL:-}" ]]; then
    release_ctl="$ELIXIR_RELEASE_CTL"
    if [[ "$release_ctl" != /* ]]; then
      echo "ELIXIR_RELEASE_CTL must be an absolute path: ${release_ctl}" >&2
      exit 2
    fi
    if [[ -z "$container" && ! -x "$release_ctl" ]]; then
      echo "ELIXIR_RELEASE_CTL is not executable: ${release_ctl}" >&2
      exit 2
    fi
    return
  fi

  if ! rows=$(discover); then
    echo "failed to scan for releases in $(where)" >&2
    exit 3
  fi
  if [[ -z "$rows" ]]; then
    echo "no running Elixir release found in $(where); run beam.release_targets to list targets" >&2
    exit 3
  fi
  if (($(wc -l <<<"$rows") > 1)); then
    echo "several releases run in $(where); pass the release argument to pick one:" >&2
    cut -f1 <<<"$rows" >&2
    exit 3
  fi
  release_ctl=$(cut -f3 <<<"$rows")
}

ctl() {
  if [[ -n "$container" ]]; then
    docker exec "$container" "$release_ctl" "$@"
  else
    "$release_ctl" "$@"
  fi
}

# Runs one fixed read on the node. Killing the rpc client does not stop work on
# the node (:erpc does not cancel it), so the limits live on the node:
#   - a deadline, past which the worker is killed there;
#   - a heap limit, which kills the worker before it can hurt the node;
#   - low priority, so the application wins under load.
# A failure comes back to the client instead of crashing the worker, because a
# crash report would reach the logger and error tracker of the application. The
# worker then exits with a reason its linked helpers do not survive, so a failed
# read leaves no tracer or buffer behind.
# Arguments: deadline in ms, the read, and what to undo if the deadline passes.
rpc() {
  local deadline_ms="$1"
  local body="$2"
  local on_deadline="${3:-:ok}"
  ctl rpc "deadline_ms = ${deadline_ms}
parent = self()

{worker, monitor} =
  spawn_monitor(fn ->
    Process.flag(:priority, :low)
    Process.flag(:max_heap_size, %{size: 33_554_432, kill: true, error_logger: false})

    outcome =
      try do
${body}
        :ok
      catch
        kind, reason -> {kind, reason, __STACKTRACE__}
      end

    send(parent, {:elixir_beam_read, self(), outcome})
    exit(:shutdown)
  end)

receive do
  {:elixir_beam_read, ^worker, :ok} ->
    Process.demonitor(monitor, [:flush])
    :ok

  {:elixir_beam_read, ^worker, {kind, reason, stacktrace}} ->
    Process.demonitor(monitor, [:flush])
    :erlang.raise(kind, reason, stacktrace)

  {:DOWN, ^monitor, :process, ^worker, :killed} ->
    raise \"the read was killed on the node, most likely for passing its 256 MiB heap limit\"

  {:DOWN, ^monitor, :process, ^worker, reason} ->
    raise \"the read stopped on the node: #{inspect(reason)}\"
after
  deadline_ms ->
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      1_000 -> :ok
    end

    ${on_deadline}
    raise \"the read did not finish within #{deadline_ms} ms, so it was stopped on the node\"
end"
}

# Says what a process is without reading anything an application put there. The
# two process dictionary keys are written by OTP, are read one key at a time, and
# print only when they have the shape OTP gives them. OTP before 26.2 can read
# only a whole dictionary, so it keeps the raw initial_call.
DICTIONARY=$(cat <<'ELIXIR'
key_reads =
  try do
    :erlang.process_info(self(), {:dictionary, :"$initial_call"})
    true
  rescue
    ArgumentError -> false
  end

dictionary_value = fn pid, key ->
  case key_reads && :erlang.process_info(pid, {:dictionary, key}) do
    {_item, value} -> value
    _none -> :undefined
  end
end
ELIXIR
)

IDENTITY="${DICTIONARY}
$(cat <<'ELIXIR'
identify = fn pid ->
  case :erlang.process_info(pid, [:registered_name, :initial_call]) do
    [registered_name: name, initial_call: raw] ->
      started_as =
        case dictionary_value.(pid, :"$initial_call") do
          {module, function, arity} = call when is_atom(module) and is_atom(function) and is_integer(arity) -> call
          _other -> raw
        end

      ancestors =
        case dictionary_value.(pid, :"$ancestors") do
          list when is_list(list) ->
            list |> Enum.filter(fn a -> is_atom(a) or is_pid(a) end) |> Enum.take(8) |> Enum.map(fn a -> if is_atom(a), do: a, else: inspect(a) end)

          _other ->
            []
        end

      application =
        case :application.get_application(pid) do
          {:ok, app} -> app
          _none -> nil
        end

      %{registered_name: name, initial_call: started_as, ancestors: ancestors, application: application}

    _gone ->
      %{}
  end
end
ELIXIR
)"

# What a port is, without its name. A port opened with {:spawn, command} is named
# by its whole command line, and that can carry a secret. So a program is reported
# by the base name of its executable, and a driver by its first word.
PORT_TYPE=$(cat <<'ELIXIR'
port_type = fn name, os_pid ->
  first = name |> List.to_string() |> String.split() |> Enum.at(0, "")

  cond do
    not is_integer(os_pid) -> first
    (base = Path.basename(first)) =~ ~r/\A[A-Za-z0-9._+-]{1,64}\z/ -> base
    true -> "(program)"
  end
end
ELIXIR
)

# One stack frame as text. A frame carries an arity, or arguments when it comes
# from an exception, and arguments are reduced to their count.
FRAME_TEXT=$(cat <<'ELIXIR'
frame_text = fn {module, function, arity, location} ->
  count = if is_list(arity), do: length(arity), else: arity

  place =
    case {location[:file], location[:line]} do
      {nil, _line} -> ""
      {file, line} -> " (#{file}:#{line})"
    end

  "#{inspect(module)}.#{function}/#{count}#{place}"
end
ELIXIR
)

if [[ -z "$mode" ]]; then
  echo "unknown mode: ${mode}" >&2
  exit 2
fi

if [[ "$mode" != "targets" ]]; then
  resolve_ctl
fi

case "$mode" in
  targets)
    if [[ -z "$container" ]]; then
      echo "== releases on this host =="
      rows=$(/bin/sh -c "$DISCOVER" 2>/dev/null) || rows=""
      if [[ -n "$rows" ]]; then
        while IFS=$'\t' read -r n r c; do
          printf 'release=%s\troot=%s\tctl=%s\n' "$n" "$r" "$c"
        done <<<"$rows"
      else
        echo "(none found)"
      fi
      echo
    fi

    echo "== releases in running containers =="
    if ! command -v docker >/dev/null 2>&1; then
      echo "(docker CLI not installed; container scan skipped)"
    else
      names=""
      if [[ -n "$container" ]]; then
        names="$container"
      elif ! names=$(docker ps --format '{{.Names}}' 2>/dev/null); then
        names=""
        echo "(docker daemon unreachable; container scan skipped)"
      fi

      found=0
      scanned=0
      while IFS= read -r cname; do
        [[ -n "$cname" ]] || continue
        if ((scanned >= 50)); then
          echo "(container scan capped at 50)"
          break
        fi
        scanned=$((scanned + 1))
        rows=$(docker exec "$cname" /bin/sh -c "$DISCOVER" 2>/dev/null) || continue
        [[ -n "$rows" ]] || continue
        while IFS=$'\t' read -r n r c; do
          printf 'container=%s\trelease=%s\troot=%s\tctl=%s\n' "$cname" "$n" "$r" "$c"
          found=$((found + 1))
        done <<<"$rows"
      done <<<"$names"

      if ((scanned == 0)); then
        [[ -n "$names" ]] || echo "(no running containers)"
      elif ((found == 0)); then
        echo "(no releases found in ${scanned} running container(s))"
      fi
    fi
    ;;

  pid)
    ctl pid
    ;;

  runtime)
    rpc 12000 "$(cat <<'ELIXIR'
snapshot = %{
  node: node(),
  otp_release: :erlang.system_info(:otp_release),
  system_version: :erlang.system_info(:system_version),
  schedulers: :erlang.system_info(:schedulers),
  schedulers_online: :erlang.system_info(:schedulers_online),
  process_count: :erlang.system_info(:process_count),
  process_limit: :erlang.system_info(:process_limit),
  port_count: :erlang.system_info(:port_count),
  port_limit: :erlang.system_info(:port_limit),
  atom_count: :erlang.system_info(:atom_count),
  atom_limit: :erlang.system_info(:atom_limit),
  ets_table_count: :ets.all() |> length(),
  run_queue: :erlang.statistics(:run_queue),
  reductions: :erlang.statistics(:reductions),
  garbage_collection: :erlang.statistics(:garbage_collection),
  io: :erlang.statistics(:io),
  wall_clock_ms: :erlang.statistics(:wall_clock) |> elem(0),
  memory: :erlang.memory()
}

IO.inspect(snapshot, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  memory)
    rpc 12000 "$(cat <<'ELIXIR'
memory = :erlang.memory() |> Enum.into(%{})

summary =
  memory
  |> Map.put(:ets_table_count, :ets.all() |> length())
  |> Map.put(:process_count, :erlang.system_info(:process_count))
  |> Map.put(:port_count, :erlang.system_info(:port_count))
  |> Map.put(:atom_count, :erlang.system_info(:atom_count))

IO.inspect(summary, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  applications)
    rpc 12000 "$(cat <<'ELIXIR'
apps =
  Application.started_applications()
  |> Enum.map(fn {app, description, version} ->
    %{app: app, description: to_string(description), version: to_string(version)}
  end)
  |> Enum.sort_by(& &1.app)

IO.inspect(apps, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  debug_tools)
    rpc 12000 "$(cat <<'ELIXIR'
tools =
  [:recon, :recon_alloc, :recon_lib, :recon_map, :recon_rec, :recon_trace, :observer_cli]
  |> Enum.map(fn module ->
    %{
      module: module,
      loaded: Code.ensure_loaded?(module),
      application: :application.get_application(module)
    }
  end)

IO.inspect(tools, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  registered)
    require_int "limit" "$limit" 1 500
    rpc 12000 "${IDENTITY}
$(cat <<ELIXIR
limit = ${limit}
keys = [:current_function, :status, :message_queue_len, :memory, :reductions]
names = Process.registered()

registered =
  names
  |> Enum.sort()
  |> Enum.take(limit)
  |> Enum.map(fn name ->
    pid = Process.whereis(name)

    info =
      case is_pid(pid) && :erlang.process_info(pid, keys) do
        info when is_list(info) -> info
        _ -> []
      end

    identity = if is_pid(pid), do: identify.(pid) |> Map.delete(:registered_name), else: %{}

    info
    |> Enum.into(%{})
    |> Map.merge(identity)
    |> Map.merge(%{name: name, pid: inspect(pid)})
  end)

IO.inspect(%{registered_total: length(names), shown: length(registered)}, pretty: true, limit: :infinity)
IO.inspect(registered, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  top_processes)
    require_int "limit" "$limit" 1 100
    require_int "window_ms" "$window_ms" 0 10000
    case "$sort_by" in
      memory|message_queue_len|reductions|total_heap_size|binary_memory) ;;
      *)
        echo "invalid sort_by: ${sort_by}" >&2
        exit 2
        ;;
    esac
    # Lifetime reductions rank what was busy at some point since boot, so they
    # are always sampled.
    if [[ "$sort_by" == "reductions" && "$window_ms" -eq 0 ]]; then
      window_ms=1000
    fi
    rpc 16000 "${IDENTITY}
$(cat <<ELIXIR
limit = ${limit}
sort_by = :${sort_by}
window_ms = ${window_ms}
read_item = if sort_by == :binary_memory, do: :binary, else: sort_by

value_of = fn
  {:binary, binaries} -> :lists.foldl(fn {_id, size, _refs}, total -> total + size end, 0, binaries)
  {_item, value} -> value
end

# The scan runs in compiled code with no interpreted step per process, and only
# the top rows are read in detail. That is what keeps a node with many processes
# affordable. A process that exits mid-scan reads as :undefined, which sorts below
# every value.
sample = fn ->
  pids = :erlang.processes() -- [self(), parent]
  :lists.zip(:lists.zipwith(&:erlang.process_info/2, pids, :lists.duplicate(length(pids), read_item)), pids)
end

started = System.monotonic_time(:millisecond)

ranked =
  cond do
    window_ms > 0 ->
      before = for {{_item, _value} = read, pid} <- sample.(), into: %{}, do: {pid, value_of.(read)}
      Process.sleep(window_ms)

      # A process born during the window counts from zero.
      for {{_item, _value} = read, pid} <- sample.(), do: {value_of.(read) - Map.get(before, pid, 0), pid}

    sort_by == :binary_memory ->
      for {{_item, _value} = read, pid} <- sample.(), do: {value_of.(read), pid}

    true ->
      sample.()
  end

sampled_ms = System.monotonic_time(:millisecond) - started
top = ranked |> :lists.sort() |> :lists.reverse() |> :lists.sublist(limit)
keys = [:current_function, :status, :message_queue_len, :memory, :total_heap_size, :heap_size, :stack_size, :reductions]

rows =
  for {score, pid} <- top, score != :undefined, info = :erlang.process_info(pid, keys), is_list(info) do
    binary_memory =
      case :erlang.process_info(pid, :binary) do
        {:binary, _binaries} = read -> value_of.(read)
        _gone -> 0
      end

    row =
      info
      |> Enum.into(%{})
      |> Map.merge(identify.(pid))
      |> Map.merge(%{pid: inspect(pid), binary_memory: binary_memory})

    if window_ms > 0, do: Map.put(row, :"#{sort_by}_delta", score), else: row
  end

IO.inspect(
  %{
    process_count: :erlang.system_info(:process_count),
    ranked_by: if(window_ms > 0, do: :"#{sort_by}_delta", else: sort_by),
    window_ms: window_ms,
    sampled_ms: sampled_ms,
    shown: length(rows)
  },
  pretty: true,
  limit: :infinity
)

IO.inspect(rows, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  process_info)
    require_erlang_pid
    rpc 12000 "${IDENTITY}
${FRAME_TEXT}
$(cat <<ELIXIR
pid = :erlang.list_to_pid(String.to_charlist("${erlang_pid}"))
keys = [:current_function, :status, :message_queue_len, :memory, :total_heap_size, :heap_size, :stack_size, :reductions, :links, :monitors, :monitored_by, :trap_exit]

result =
  case :erlang.process_info(pid, keys) do
    :undefined ->
      %{pid: inspect(pid), error: :process_not_found}

    info ->
      binary_memory =
        case :erlang.process_info(pid, :binary) do
          {:binary, binaries} -> :lists.foldl(fn {_id, size, _refs}, total -> total + size end, 0, binaries)
          _gone -> 0
        end

      stack =
        case :erlang.process_info(pid, :current_stacktrace) do
          {:current_stacktrace, frames} -> Enum.map(frames, frame_text)
          _gone -> []
        end

      identify.(pid)
      |> Map.merge(%{pid: inspect(pid), info: info, binary_memory: binary_memory, current_stacktrace: stack})
  end

IO.inspect(result, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  supervisor_tree)
    require_int "depth" "$depth" 0 5
    require_int "limit" "$limit" 1 1000
    if [[ ! "$registered_name" =~ ^[A-Za-z_][A-Za-z0-9_.@-]{0,127}$ ]]; then
      echo "invalid registered_name: ${registered_name}" >&2
      exit 2
    fi

    rpc 16000 "${DICTIONARY}
$(cat <<ELIXIR
raw_name = "${registered_name}"
depth = ${depth}
limit = ${limit}
call_ms = 1000
max_rows = 1000
rows = :counters.new(1, [])

to_existing_name = fn raw ->
  candidates =
    if String.starts_with?(raw, "Elixir.") do
      [raw]
    else
      ["Elixir." <> raw, raw]
    end

  Enum.find_value(candidates, fn candidate ->
    try do
      {:ok, String.to_existing_atom(candidate)}
    rescue
      ArgumentError -> nil
    end
  end) || {:error, :unknown_existing_atom}
end

# Only a supervisor understands these calls. An ordinary GenServer crashes on an
# unexpected call, so a read must never send one to whatever a name points at.
is_supervisor = fn pid ->
  initial_call =
    if key_reads do
      dictionary_value.(pid, :"\$initial_call")
    else
      case :erlang.process_info(pid, :dictionary) do
        {:dictionary, entries} -> :proplists.get_value(:"\$initial_call", entries)
        _gone -> nil
      end
    end

  match?({:supervisor, _module, _arity}, initial_call)
end

# A child id can be any term, so only its atoms, numbers, and shape are printed.
plain_id = fn plain_id, term ->
  cond do
    is_atom(term) or is_number(term) -> term
    is_tuple(term) -> term |> Tuple.to_list() |> Enum.map(fn item -> plain_id.(plain_id, item) end) |> List.to_tuple()
    true -> :"(term)"
  end
end

# The count comes first because listing a large supervisor copies every child and
# can run a node out of memory. Both calls are bounded: a supervisor stuck in a
# slow start answers neither, and an unbounded call would wait forever. Only the
# kind of failure is kept, because an exit reason can hold anything.
children_of = fn pid ->
  try do
    counts = Map.new(:gen_server.call(pid, :count_children, call_ms))
    total = Map.get(counts, :supervisors, 0) + Map.get(counts, :workers, 0)

    if total > limit do
      {:too_many, total}
    else
      {:ok, :gen_server.call(pid, :which_children, call_ms), total}
    end
  catch
    :exit, {:timeout, _call} -> {:unreachable, :timeout}
    :exit, {:noproc, _call} -> {:unreachable, :noproc}
    :exit, _reason -> {:unreachable, :terminated}
  end
end

# A child spec can say type: :supervisor about anything, so each process passes
# the same check as the root before it is called.
walk = fn walk, pid, depth_left ->
  if is_supervisor.(pid) do
    case children_of.(pid) do
      {:unreachable, reason} ->
        %{error: :unreachable, reason: reason}

      {:too_many, total} ->
        %{children_total: total, children_shown: 0}

      {:ok, children, total} ->
        listed =
          Enum.flat_map(children, fn {id, child, type, modules} ->
            if :counters.get(rows, 1) >= max_rows do
              []
            else
              :counters.add(rows, 1, 1)

              row = %{
                id: plain_id.(plain_id, id),
                child: if(is_pid(child), do: inspect(child), else: child),
                type: type,
                modules: modules
              }

              if type == :supervisor and is_pid(child) and depth_left > 0 do
                [Map.merge(row, walk.(walk, child, depth_left - 1))]
              else
                [row]
              end
            end
          end)

        %{children_total: total, children_shown: length(listed), children: listed}
    end
  else
    %{error: :not_a_supervisor}
  end
end

result =
  case to_existing_name.(raw_name) do
    {:ok, name} ->
      pid = Process.whereis(name)

      cond do
        pid == nil -> %{name: name, error: :not_registered}
        is_pid(pid) -> Map.merge(%{name: name, pid: inspect(pid)}, walk.(walk, pid, depth))
        true -> %{name: name, pid: inspect(pid), error: :not_a_supervisor}
      end

    {:error, reason} ->
      %{requested_name: raw_name, error: reason}
  end

IO.inspect(%{rows: :counters.get(rows, 1), stopped_at_row_limit: :counters.get(rows, 1) >= max_rows}, pretty: true, limit: :infinity)
IO.inspect(result, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  ets_tables)
    require_int "limit" "$limit" 1 500
    case "$sort_by" in
      memory|size) ;;
      *)
        echo "invalid sort_by: ${sort_by}" >&2
        exit 2
        ;;
    esac
    rpc 16000 "${IDENTITY}
$(cat <<ELIXIR
limit = ${limit}
sort_key = if "${sort_by}" == "memory", do: :memory_bytes, else: :size
wordsize = :erlang.system_info(:wordsize)

tables =
  :ets.all()
  |> Enum.map(fn t ->
    case :ets.info(t) do
      :undefined ->
        nil

      info ->
        %{
          table: inspect(t),
          name: info[:name],
          type: info[:type],
          size: info[:size],
          memory_bytes: (info[:memory] || 0) * wordsize,
          owner: info[:owner],
          protection: info[:protection],
          named_table: info[:named_table]
        }
    end
  end)
  |> Enum.reject(&is_nil/1)

summary = %{
  table_count: length(tables),
  total_memory_bytes: tables |> Enum.map(& &1.memory_bytes) |> Enum.sum()
}

top =
  tables
  |> Enum.sort_by(&Map.get(&1, sort_key, 0))
  |> Enum.reverse()
  |> Enum.take(limit)
  |> Enum.map(fn table ->
    owner = identify.(table.owner)
    Map.merge(table, %{owner: inspect(table.owner), owner_name: owner[:registered_name], owner_initial_call: owner[:initial_call]})
  end)

IO.inspect(summary, pretty: true, limit: :infinity)
IO.inspect(top, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  allocators)
    rpc 12000 "$(cat <<'ELIXIR'
unless Code.ensure_loaded?(:recon_alloc) and function_exported?(:recon_alloc, :memory, 1) do
  raise "recon_alloc is not available in this release"
end

summary = %{
  allocated_bytes: :recon_alloc.memory(:allocated),
  used_bytes: :recon_alloc.memory(:used),
  usage_ratio: :recon_alloc.memory(:usage),
  erlang_reported_total_bytes: :erlang.memory(:total)
}

by_type =
  :recon_alloc.memory(:allocated_types)
  |> Enum.map(fn {allocator, bytes} -> %{allocator: allocator, allocated_bytes: bytes} end)
  |> Enum.sort_by(& &1.allocated_bytes)
  |> Enum.reverse()

IO.inspect(summary, pretty: true, limit: :infinity)
IO.inspect(by_type, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  bin_leak)
    require_int "limit" "$limit" 1 100
    rpc 55000 "$(cat <<ELIXIR
unless Code.ensure_loaded?(:recon) and function_exported?(:recon, :bin_leak, 1) do
  raise "recon is not available in this release"
end

results =
  :recon.bin_leak(${limit})
  |> Enum.map(fn {pid, delta, info} ->
    %{pid: inspect(pid), binaries_freed_by_gc: -delta, info: info}
  end)

IO.inspect(results, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  scheduler_usage)
    require_int "sample_ms" "$sample_ms" 100 5000
    rpc 16000 "$(cat <<ELIXIR
unless Code.ensure_loaded?(:recon) and function_exported?(:recon, :scheduler_usage, 1) do
  raise "recon is not available in this release"
end

sample_ms = ${sample_ms}

usage =
  :recon.scheduler_usage(sample_ms)
  |> Enum.map(fn {id, ratio} -> %{scheduler: id, usage: Float.round(ratio * 1.0, 4)} end)

IO.inspect(
  %{
    schedulers: :erlang.system_info(:schedulers),
    schedulers_online: :erlang.system_info(:schedulers_online),
    sample_ms: sample_ms
  },
  pretty: true,
  limit: :infinity
)

IO.inspect(usage, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  ports)
    require_int "limit" "$limit" 1 100
    rpc 12000 "${IDENTITY}
${PORT_TYPE}
$(cat <<ELIXIR
limit = ${limit}
socket_drivers = [~c"tcp_inet", ~c"udp_inet", ~c"sctp_inet"]

ports =
  for port <- :erlang.ports(), info = :erlang.port_info(port), is_list(info), {:queue_size, queue} <- [:erlang.port_info(port, :queue_size)] do
    %{
      port: port,
      driver: port_type.(info[:name], info[:os_pid]),
      socket: not is_integer(info[:os_pid]) and info[:name] in socket_drivers,
      owner: info[:connected],
      input: info[:input],
      output: info[:output],
      queue: queue
    }
  end

by_driver =
  ports
  |> Enum.map(& &1.driver)
  |> Enum.frequencies()
  |> Enum.sort_by(fn {_name, count} -> count end)
  |> Enum.reverse()

by_owner =
  ports
  |> Enum.group_by(& &1.owner)
  |> Enum.sort_by(fn {_owner, owned} -> -length(owned) end)
  |> Enum.take(limit)
  |> Enum.map(fn {owner, owned} ->
    identity = if is_pid(owner), do: identify.(owner), else: %{}

    Map.merge(identity, %{
      owner: inspect(owner),
      ports: length(owned),
      by_driver: owned |> Enum.map(& &1.driver) |> Enum.frequencies(),
      bytes_in: owned |> Enum.map(& &1.input) |> Enum.sum(),
      bytes_out: owned |> Enum.map(& &1.output) |> Enum.sum(),
      bytes_queued: owned |> Enum.map(& &1.queue) |> Enum.sum()
    })
  end)

# Only the exact socket drivers: these calls reach the driver through port_control,
# and another driver could read that operation as something else.
address = fn result ->
  case result do
    {:ok, {ip, number}} -> "#{:inet.ntoa(ip)}:#{number}"
    _none -> nil
  end
end

queued =
  ports
  |> Enum.filter(&(&1.queue > 0))
  |> Enum.sort_by(&(-&1.queue))
  |> Enum.take(limit)
  |> Enum.map(fn row ->
    %{
      port: inspect(row.port),
      driver: row.driver,
      owner: inspect(row.owner),
      owner_name: is_pid(row.owner) && identify.(row.owner)[:registered_name],
      bytes_queued: row.queue,
      local: if(row.socket, do: address.(:inet.sockname(row.port))),
      peer: if(row.socket, do: address.(:inet.peername(row.port)))
    }
  end)

IO.inspect(
  %{
    port_count: length(ports),
    port_limit: :erlang.system_info(:port_limit),
    by_driver: by_driver,
    owners_shown: length(by_owner),
    queued_shown: length(queued)
  },
  pretty: true,
  limit: :infinity
)

IO.puts("== ports by owner ==")
IO.inspect(by_owner, pretty: true, limit: :infinity)
IO.puts("== bytes waiting to be written ==")
IO.inspect(queued, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  wait_graph)
    require_int "limit" "$limit" 1 200
    rpc 16000 "${IDENTITY}
$(cat <<ELIXIR
limit = ${limit}
gen_call = {:gen, :do_call, 4}
task_awaits = [{Task, :await, 2}, {Task, :await_receive, 3}]
pids = :erlang.processes() -- [self(), parent]
current = :lists.zipwith(&:erlang.process_info/2, pids, :lists.duplicate(length(pids), :current_function))
functions = for {{:current_function, function}, pid} <- :lists.zip(current, pids), do: {function, pid}

monitored = fn pid ->
  case :erlang.process_info(pid, :monitors) do
    {:monitors, monitors} -> for {:process, target} <- monitors, do: target
    _gone -> []
  end
end

reads = for {function, pid} <- functions, function == gen_call, do: {pid, monitored.(pid)}
task_waiters = for {function, pid} <- functions, :lists.member(function, task_awaits), do: pid

# A process in a gen call monitors what it waits for, so a single monitor is the
# target. With more, their order says nothing about which one it is. A process in
# Task.await can outlive the monitor of its task, so its monitors are never an
# answer. Both stay candidates, and count toward no target or cycle.
waits = for {pid, [target]} <- reads, into: %{}, do: {pid, target}

uncertain =
  for({pid, [_first, _second | _rest] = targets} <- reads, do: {pid, targets}) ++
    for(pid <- task_waiters, do: {pid, monitored.(pid)})

is_local = fn target -> is_pid(target) and node(target) == node() end

name_of = fn target ->
  identity = if is_local.(target), do: identify.(target), else: %{}

  case identity do
    %{registered_name: name} when is_atom(name) -> inspect(name)
    %{initial_call: call} -> "#{inspect(target)} #{inspect(call)}"
    _other -> inspect(target)
  end
end

# Each process has at most one target, so a walk from every unvisited waiter finds
# every cycle and visits each process once.
trace_path = fn trace_path, at, path, on_path, visited ->
  cond do
    Map.has_key?(on_path, at) ->
      {[at | Enum.reverse(Enum.take_while(path, fn pid -> pid != at end))], Map.merge(visited, on_path)}

    Map.has_key?(visited, at) or not Map.has_key?(waits, at) ->
      {nil, Map.merge(visited, on_path)}

    true ->
      trace_path.(trace_path, Map.get(waits, at), [at | path], Map.put(on_path, at, true), visited)
  end
end

{found, _visited} =
  Enum.reduce(Map.keys(waits), {[], %{}}, fn pid, {cycles, visited} ->
    if Map.has_key?(visited, pid) do
      {cycles, visited}
    else
      {cycle, visited} = trace_path.(trace_path, pid, [], %{}, visited)
      {if(cycle, do: [cycle | cycles], else: cycles), visited}
    end
  end)

# A process in a gen call that still has what it waits for is waiting, with one
# monitor, and the reply or the death of its target would wake it. So status
# :waiting excludes a reply it has not run to read, a target that already died, and
# a suspended process, and the second read lets a passing moment go by.
still_waiting = fn pid ->
  :erlang.process_info(pid, [:current_function, :status]) == [current_function: gen_call, status: :waiting] and
    monitored.(pid) == [Map.get(waits, pid)]
end

cycles =
  case found do
    [] ->
      []

    _some ->
      Process.sleep(200)
      Enum.filter(found, fn cycle -> Enum.all?(cycle, still_waiting) end)
  end

by_target =
  waits
  |> Enum.group_by(fn {_pid, target} -> target end, fn {pid, _target} -> pid end)
  |> Enum.sort_by(fn {_target, waiters} -> -length(waiters) end)

IO.inspect(
  %{
    blocked_in_calls: length(reads),
    targets: length(by_target),
    targets_shown: min(limit, length(by_target)),
    uncertain_waiters: length(uncertain),
    uncertain_shown: min(limit, length(uncertain)),
    cycles: length(cycles)
  },
  pretty: true,
  limit: :infinity
)

IO.puts("== deadlock cycles: each member holds one monitor and is still waiting 200 ms later ==")
IO.inspect(Enum.map(cycles, fn cycle -> Enum.map(cycle, name_of) end), pretty: true, limit: :infinity)
IO.puts("== waiters by target ==")

by_target
|> Enum.take(limit)
|> Enum.map(fn {target, waiters} ->
  state =
    if is_local.(target) do
      :erlang.process_info(target, [:current_function, :status, :message_queue_len])
    end

  %{target: name_of.(target), waiters: length(waiters), sample_waiters: waiters |> Enum.take(5) |> Enum.map(name_of), state: state}
end)
|> IO.inspect(pretty: true, limit: :infinity)

IO.puts("== waiting, but on one of several candidates ==")

uncertain
|> Enum.take(limit)
|> Enum.map(fn {pid, targets} -> %{waiter: name_of.(pid), candidates: targets |> Enum.take(5) |> Enum.map(name_of), candidate_count: length(targets)} end)
|> IO.inspect(pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  orphans)
    require_int "limit" "$limit" 1 200
    rpc 16000 "${IDENTITY}
$(cat <<ELIXIR
limit = ${limit}
init = :erlang.whereis(:init)
pids = :erlang.processes() -- [self(), parent]
items = [:links, :monitors, :monitored_by, :group_leader, :memory]
reads = :lists.zipwith(&:erlang.process_info/2, pids, :lists.duplicate(length(pids), items))

# Group leader init marks the runtime system own processes, not application work.
found =
  for {[links: [], monitors: [], monitored_by: [], group_leader: leader, memory: memory], pid} <- :lists.zip(reads, pids), leader != init do
    {memory, pid}
  end

keys = [:current_function, :status, :message_queue_len, :memory, :reductions]

rows =
  for {_memory, pid} <- found |> :lists.sort() |> :lists.reverse() |> :lists.sublist(limit), info = :erlang.process_info(pid, keys), is_list(info) do
    info |> Enum.into(%{}) |> Map.merge(identify.(pid)) |> Map.put(:pid, inspect(pid))
  end

IO.inspect(%{candidates: length(found), shown: length(rows)}, pretty: true, limit: :infinity)
IO.inspect(rows, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  process_stacks)
    require_erlang_pid
    require_int "samples" "$samples" 1 200
    require_int "interval_ms" "$interval_ms" 1 50
    rpc 16000 "${IDENTITY}
${FRAME_TEXT}
$(cat <<ELIXIR
pid = :erlang.list_to_pid(String.to_charlist("${erlang_pid}"))
samples = ${samples}
interval_ms = ${interval_ms}

taken =
  Enum.reduce_while(1..samples, [], fn _sample, taken ->
    case :erlang.process_info(pid, [:current_stacktrace, :status]) do
      [current_stacktrace: frames, status: status] ->
        Process.sleep(interval_ms)
        {:cont, [{Enum.map(frames, frame_text), status} | taken]}

      _gone ->
        {:halt, taken}
    end
  end)

stacks =
  taken
  |> Enum.frequencies_by(fn {frames, _status} -> frames end)
  |> Enum.sort_by(fn {_frames, count} -> -count end)

IO.inspect(
  identify.(pid)
  |> Map.merge(%{
    pid: inspect(pid),
    samples_taken: length(taken),
    interval_ms: interval_ms,
    status_counts: Enum.frequencies_by(taken, fn {_frames, status} -> status end),
    distinct_stacks: length(stacks),
    stacks_shown: min(20, length(stacks))
  }),
  pretty: true,
  limit: :infinity
)

stacks
|> Enum.take(20)
|> Enum.map(fn {frames, count} -> %{samples: count, frames: frames} end)
|> IO.inspect(pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  mailbox_senders)
    require_erlang_pid
    require_int "duration_ms" "$duration_ms" 100 5000
    require_int "max_events" "$max_events" 1 100000
    rpc "$((duration_ms + 5000))" "${IDENTITY}
${PORT_TYPE}
$(cat <<ELIXIR
unless Code.ensure_loaded?(:trace) and function_exported?(:trace, :session_create, 3) do
  raise "this action needs OTP 27 or newer, which traces in an isolated session; this node runs OTP #{:erlang.system_info(:otp_release)}"
end

target = :erlang.list_to_pid(String.to_charlist("${erlang_pid}"))
duration_ms = ${duration_ms}
max_events = ${max_events}
max_tracer_bytes = 67_108_864
max_tracer_backlog = 1_000

registered_name =
  case :erlang.process_info(target, :registered_name) do
    :undefined -> raise "process not found: #{inspect(target)}"
    {:registered_name, name} -> name
    [] -> nil
  end

# A message can be addressed by pid or by registered name, and a send trace matches
# on what the sender wrote.
destinations =
  if registered_name do
    [target, registered_name, {registered_name, node()}]
  else
    [target]
  end

# The watch below has to keep up with the tracer, so it does not yield to the app.
Process.flag(:priority, :normal)
reader = self()

# Each trace event carries the whole message, and a queued one keeps a large binary
# alive. So the tracer runs ahead of the senders it counts, keeps only who sent each
# message, and the watch stops tracing as soon as it falls behind or holds too much.
tracer =
  spawn_link(fn ->
    Process.flag(:priority, :high)
    Process.flag(:max_heap_size, %{size: 8_388_608, kill: true, error_logger: false, include_shared_binaries: true})

    count = fn count, seen, senders ->
      receive do
        {:trace, sender, :send, _message, to} ->
          # The match spec does not filter what a port sends, so every event is checked.
          if :lists.member(to, destinations) do
            if seen + 1 == max_events, do: send(reader, :event_limit)
            count.(count, seen + 1, Map.update(senders, sender, 1, &(&1 + 1)))
          else
            count.(count, seen, senders)
          end

        :report ->
          send(reader, {:senders, seen, senders})
      end
    end

    count.(count, 0, %{})
  end)

session = :trace.session_create(:elixir_beam_senders, tracer, [])
started = System.monotonic_time(:millisecond)

watch = fn watch ->
  receive do
    :event_limit -> :event_limit
  after
    50 ->
      [memory: tracer_bytes, message_queue_len: backlog] = :erlang.process_info(tracer, [:memory, :message_queue_len])

      cond do
        tracer_bytes > max_tracer_bytes -> :tracer_memory_limit
        backlog > max_tracer_backlog -> :tracer_fell_behind
        System.monotonic_time(:millisecond) - started >= duration_ms -> :window_ended
        true -> watch.(watch)
      end
  end
end

stopped =
  try do
    :trace.send(session, Enum.map(destinations, fn destination -> {[destination, :_], [], []} end), [])
    :trace.process(session, :all, true, [:send])

    # A port sends only to the process connected to it. The match spec does not
    # filter ports, so tracing all of them would copy all socket traffic here.
    for port <- :erlang.ports(), :erlang.port_info(port, :connected) == {:connected, target} do
      try do
        :trace.port(session, port, true, [:send])
      rescue
        # A port can close between those two reads, which is not a failure.
        error in ArgumentError ->
          if :erlang.port_info(port) != :undefined, do: reraise(error, __STACKTRACE__)
      end
    end

    watch.(watch)
  after
    :trace.session_destroy(session)
  end

traced_ms = System.monotonic_time(:millisecond) - started
send(tracer, :report)

{seen, senders} =
  receive do
    {:senders, seen, senders} -> {seen, senders}
  after
    3_000 -> raise "the tracer did not report in time"
  end

IO.inspect(
  %{
    target: inspect(target),
    traced_ms: traced_ms,
    stopped: stopped,
    messages_seen: seen,
    senders: map_size(senders),
    senders_shown: min(25, map_size(senders)),
    message_contents: :not_recorded,
    addressed_as: Enum.map(destinations, &inspect/1)
  },
  pretty: true,
  limit: :infinity
)

senders
|> Enum.sort_by(fn {_sender, messages} -> -messages end)
|> Enum.take(25)
|> Enum.map(fn {sender, messages} ->
  identity =
    if is_pid(sender) do
      identify.(sender)
    else
      case :erlang.port_info(sender) do
        info when is_list(info) -> %{driver: port_type.(info[:name], info[:os_pid])}
        _closed -> %{}
      end
    end

  Map.merge(identity, %{sender: inspect(sender), messages: messages})
end)
|> IO.inspect(pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  recon_trace_calls)
    if [[ ! "$trace_module" =~ ^[A-Za-z_][A-Za-z0-9_.@-]{0,127}$ ]]; then
      echo "invalid module: ${trace_module}" >&2
      exit 2
    fi
    if [[ ! "$trace_function" =~ ^[A-Za-z_][A-Za-z0-9_!?@]{0,127}$ ]]; then
      echo "invalid function: ${trace_function}" >&2
      exit 2
    fi
    require_int "arity" "$trace_arity" 0 255
    require_int "max_traces" "$max_traces" 1 100
    require_int "duration_ms" "$duration_ms" 100 10000
    require_bool "include_args" "$include_args"
    require_bool "include_return" "$include_return"
    case "$pid_scope" in
      existing|new|all) ;;
      *)
        echo "invalid pid_scope: ${pid_scope}" >&2
        exit 2
        ;;
    esac

    # A killed worker skips its own clear below, so the deadline path clears too.
    rpc "$((duration_ms + 5000))" "$(cat <<ELIXIR
raw_module = "${trace_module}"
raw_function = "${trace_function}"
arity = ${trace_arity}
max_traces = ${max_traces}
duration_ms = ${duration_ms}
pid_scope = :${pid_scope}
include_args = ${include_args}
include_return = ${include_return}

to_existing_module = fn raw ->
  candidates =
    if String.starts_with?(raw, "Elixir.") do
      [raw]
    else
      ["Elixir." <> raw, raw]
    end

  Enum.find_value(candidates, fn candidate ->
    try do
      {:ok, String.to_existing_atom(candidate)}
    rescue
      ArgumentError -> nil
    end
  end) || {:error, :unknown_existing_module}
end

to_existing_function = fn raw ->
  try do
    {:ok, String.to_existing_atom(raw)}
  rescue
    ArgumentError -> {:error, :unknown_existing_function}
  end
end

unless Code.ensure_loaded?(:recon_trace) and function_exported?(:recon_trace, :calls, 3) do
  raise "recon_trace is not available in this release"
end

with {:ok, module} <- to_existing_module.(raw_module),
     {:ok, function} <- to_existing_function.(raw_function) do
  trace_pattern =
    if include_return do
      args = List.duplicate(:_, arity)
      {module, function, [{args, [], [{:return_trace}]}]}
    else
      {module, function, arity}
    end

  trace_opts = [
    {:pid, pid_scope},
    {:args, if(include_args, do: :args, else: :arity)}
  ]

  {:ok, io} = StringIO.open("")

  started =
    try do
      started = :recon_trace.calls(trace_pattern, max_traces, Keyword.put(trace_opts, :io_server, io))
      Process.sleep(duration_ms)
      started
    after
      :recon_trace.clear()
    end

  {:ok, {_input, trace_output}} = StringIO.close(io)

  IO.puts("== trace_setup ==")
  IO.inspect(
    %{
      module: module,
      function: function,
      arity: arity,
      max_traces: max_traces,
      duration_ms: duration_ms,
      pid_scope: pid_scope,
      include_args: include_args,
      include_return: include_return,
      trace_patterns_started: started
    },
    pretty: true,
    limit: :infinity
  )

  IO.puts("")
  IO.puts("== trace_output ==")
  IO.write(trace_output)
else
  {:error, reason} ->
    IO.inspect(%{error: reason, module: raw_module, function: raw_function})
end
ELIXIR
)" ":recon_trace.clear()"
    ;;

  recon_trace_clear)
    rpc 12000 "$(cat <<'ELIXIR'
unless Code.ensure_loaded?(:recon_trace) and function_exported?(:recon_trace, :clear, 0) do
  raise "recon_trace is not available in this release"
end

IO.inspect(%{cleared: :recon_trace.clear()})
ELIXIR
)"
    ;;

  *)
    echo "unknown mode: ${mode}" >&2
    exit 2
    ;;
esac
