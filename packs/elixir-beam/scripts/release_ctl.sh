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

rpc() {
  ctl rpc "$1"
}

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
    rpc "$(cat <<'ELIXIR'
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
    rpc "$(cat <<'ELIXIR'
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
    rpc "$(cat <<'ELIXIR'
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
    rpc "$(cat <<'ELIXIR'
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
    rpc "$(cat <<ELIXIR
limit = ${limit}
keys = [:current_function, :initial_call, :status, :message_queue_len, :memory, :reductions]

registered =
  Process.registered()
  |> Enum.sort()
  |> Enum.take(limit)
  |> Enum.map(fn name ->
    pid = Process.whereis(name)

    info =
      case pid && :erlang.process_info(pid, keys) do
        info when is_list(info) -> info
        _ -> []
      end

    info_map = Enum.into(info, %{})
    Map.merge(info_map, %{name: name, pid: inspect(pid)})
  end)

IO.inspect(registered, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  top_processes)
    require_int "limit" "$limit" 1 100
    case "$sort_by" in
      memory|message_queue_len|reductions|total_heap_size) ;;
      *)
        echo "invalid sort_by: ${sort_by}" >&2
        exit 2
        ;;
    esac
    rpc "$(cat <<ELIXIR
limit = ${limit}
sort_by = :${sort_by}
keys = [:registered_name, :current_function, :initial_call, :status, :message_queue_len, :memory, :total_heap_size, :heap_size, :stack_size, :reductions]

processes =
  Process.list()
  |> Enum.flat_map(fn pid ->
    case :erlang.process_info(pid, keys) do
      :undefined ->
        []

      info ->
        info_map = Enum.into(info, %{})
        [Map.put(info_map, :pid, inspect(pid))]
    end
  end)
  |> Enum.sort_by(fn row -> Map.get(row, sort_by, 0) end)
  |> Enum.reverse()
  |> Enum.take(limit)

IO.inspect(processes, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  process_info)
    if [[ ! "$erlang_pid" =~ ^\<[0-9]+\.[0-9]+\.[0-9]+\>$ ]]; then
      echo "invalid erlang_pid: ${erlang_pid}" >&2
      exit 2
    fi

    rpc "$(cat <<ELIXIR
pid = :erlang.list_to_pid(String.to_charlist("${erlang_pid}"))
keys = [:registered_name, :current_function, :initial_call, :status, :message_queue_len, :memory, :total_heap_size, :heap_size, :stack_size, :reductions, :links, :monitors, :monitored_by]

result =
  case :erlang.process_info(pid, keys) do
    :undefined -> %{pid: inspect(pid), error: :process_not_found}
    info -> %{pid: inspect(pid), info: info}
  end

IO.inspect(result, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  supervisor_tree)
    require_int "depth" "$depth" 0 5
    if [[ ! "$registered_name" =~ ^[A-Za-z_][A-Za-z0-9_.@-]{0,127}$ ]]; then
      echo "invalid registered_name: ${registered_name}" >&2
      exit 2
    fi

    rpc "$(cat <<ELIXIR
raw_name = "${registered_name}"
depth = ${depth}

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

format_child = fn {id, child, type, modules} ->
  %{
    id: id,
    child: if(is_pid(child), do: inspect(child), else: child),
    type: type,
    modules: modules
  }
end

walk = fn walk, pid, depth_left ->
  children =
    try do
      :supervisor.which_children(pid)
    catch
      :exit, reason -> {:error, reason}
    end

  case children do
    {:error, reason} ->
      %{error: :not_a_supervisor_or_unreachable, reason: inspect(reason)}

    children ->
      Enum.map(children, fn child ->
        row = format_child.(child)

        case {child, depth_left} do
          {{_id, child_pid, :supervisor, _modules}, n} when is_pid(child_pid) and n > 0 ->
            Map.put(row, :children, walk.(walk, child_pid, n - 1))

          _ ->
            row
        end
      end)
  end
end

result =
  case to_existing_name.(raw_name) do
    {:ok, name} ->
      case Process.whereis(name) do
        nil -> %{name: name, error: :not_registered}
        pid -> %{name: name, pid: inspect(pid), children: walk.(walk, pid, depth)}
      end

    {:error, reason} ->
      %{requested_name: raw_name, error: reason}
  end

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
    rpc "$(cat <<ELIXIR
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
          owner: inspect(info[:owner]),
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

IO.inspect(summary, pretty: true, limit: :infinity)
IO.inspect(top, pretty: true, limit: :infinity)
ELIXIR
)"
    ;;

  allocators)
    rpc "$(cat <<'ELIXIR'
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
    rpc "$(cat <<ELIXIR
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
    rpc "$(cat <<ELIXIR
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
    rpc "$(cat <<'ELIXIR'
ports = :erlang.ports()

by_driver =
  ports
  |> Enum.map(fn p ->
    case :erlang.port_info(p, :name) do
      {:name, name} -> List.to_string(name)
      :undefined -> "(dead)"
    end
  end)
  |> Enum.frequencies()
  |> Enum.sort_by(fn {_name, count} -> count end)
  |> Enum.reverse()

IO.inspect(
  %{
    port_count: length(ports),
    port_limit: :erlang.system_info(:port_limit),
    by_driver: by_driver
  },
  pretty: true,
  limit: :infinity
)
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

    rpc "$(cat <<ELIXIR
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

  started = :recon_trace.calls(trace_pattern, max_traces, Keyword.put(trace_opts, :io_server, io))

  try do
    Process.sleep(duration_ms)
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
)"
    ;;

  recon_trace_clear)
    rpc "$(cat <<'ELIXIR'
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
