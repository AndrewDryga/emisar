defmodule Emisar.Config do
  @moduledoc """
  Application-config reads with a **test-only** per-process override.

  In every non-test environment `get_env/3` and `fetch_env!/2` read straight
  from `Application` — zero override surface, so dev and prod resolve config
  exactly as the release does. In `:test` a read first consults a
  process-scoped override (set by `put_override/3`, owned by the test's own
  process), resolved across the current process, a `:last_caller_pid` planted
  by `EmisarWeb.Sandbox` from the Ecto-sandbox `user-agent`, and the root of
  the `$ancestors` / `$callers` stacks. That lets an async test, a LiveView,
  and a real browser session each override config for its own request without
  mutating global `Application` env — the replacement for `Application.put_env`,
  which races under `async: true`.

  Mirrors Firezone's `Domain.Config` / `Domain.Config.Resolver`.
  """

  # The override lives in the owning (test) process's dictionary, so it dies
  # with that process — no `on_exit` restore, no global mutation. This is the
  # one sanctioned `Process.put` for non-request state; it is NEVER ambient
  # request/audit metadata (that stays an `%Emisar.RequestContext{}`).
  # credo:disable-for-this-file Emisar.Checks.NoProcessDictionary

  if Mix.env() == :test do
    @unset :__emisar_config_unset__

    @doc "Read `key`, preferring a per-process override, then `Application` env."
    def get_env(app, key, default \\ nil) do
      case fetch_override(app, key) do
        {:ok, value} -> value
        :error -> Application.get_env(app, key, default)
      end
    end

    @doc "Read required `key`, preferring a per-process override, then `Application` env."
    def fetch_env!(app, key) do
      case fetch_override(app, key) do
        {:ok, value} -> value
        :error -> Application.fetch_env!(app, key)
      end
    end

    @doc """
    Override `key` for the calling process (and any process that reaches it via
    `$callers` / `$ancestors` / a sandbox `:last_caller_pid`). Test-only.
    """
    def put_override(app \\ :emisar, key, value) do
      Process.put({app, key}, value)
      :ok
    end

    # Try the current process, then the sandbox owner planted by the browser
    # bridge, then the root of $ancestors / $callers — reading each owner's
    # dictionary directly. A stored `nil`/`false` override still resolves
    # (a `:__emisar_config_unset__` sentinel distinguishes "unset" from "nil").
    defp fetch_override(app, key) do
      pkey = {app, key}

      with :error <- own_override(pkey),
           :error <- peek_override(Process.get(:last_caller_pid), pkey),
           :error <- peek_override(stack_root(:"$ancestors"), pkey) do
        peek_override(stack_root(:"$callers"), pkey)
      end
    end

    defp own_override(pkey) do
      case Process.get(pkey, @unset) do
        @unset -> :error
        value -> {:ok, value}
      end
    end

    defp peek_override(nil, _pkey), do: :error

    defp peek_override(name, pkey) when is_atom(name),
      do: peek_override(Process.whereis(name), pkey)

    defp peek_override(pid, pkey) when is_pid(pid) do
      with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
           {^pkey, value} <- List.keyfind(dictionary, pkey, 0) do
        {:ok, value}
      else
        _ -> :error
      end
    end

    defp stack_root(stack) do
      case Process.get(stack) do
        [_ | _] = pids -> List.last(pids)
        _ -> nil
      end
    end
  else
    def get_env(app, key, default \\ nil), do: Application.get_env(app, key, default)
    def fetch_env!(app, key), do: Application.fetch_env!(app, key)
  end
end
