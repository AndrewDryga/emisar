defmodule Emisar.Analytics do
  @moduledoc """
  The single egress point for product & usage analytics (Mixpanel).
  Server-side by design — emisar ships no third-party tracking script
  (see `.agent/specs/mixpanel-analytics.md`). Everything funnels through
  here so the event names, the property shapes, and the one network
  destination live in one auditable place — the analytics counterpart to
  `Emisar.Audit.Events` and `Emisar.Telemetry`.

  `track/4`, `set_people/3`, and `set_group/4` build the Mixpanel payload,
  then hand it to the config-swapped `MixpanelClient` on a supervised,
  fire-and-forget Task (`EmisarWeb.TaskSupervisor`) — analytics is
  best-effort and never blocks or fails the caller's request. The whole
  module is a no-op unless `:mixpanel_enabled` is true (prod with a
  `MIXPANEL_TOKEN`), so dev/test and the per-seam callers stay free.

  Identity is server-side (the Mixpanel "Simplified ID Merge" pattern):
  pass `:device_id` (the anonymous session id) and/or `:user_id` (the
  stable `user.id`) in `opts`; sending both on the first identified event
  stitches the pre-signup journey to the user. `distinct_id` is the
  canonical id callers report against (the user id once known, else the
  device id). Product builders live in `Emisar.Analytics.Events`.
  """

  import Emisar.Maps, only: [put_present: 4]
  alias Emisar.Analytics.MixpanelClient

  # Values dropped from analytics payloads — never send a null/empty property.
  @blanks [nil, ""]

  @doc """
  Track `event` for `distinct_id` with flat `properties`. `opts`:
  `:device_id` / `:user_id` (identity merge), `:ip` (geo — omit or `"0"`
  to suppress). Nil/blank properties are dropped (never sent as null).
  Returns `:ok` always.
  """
  @spec track(String.t(), String.t(), map(), keyword()) :: :ok
  def track(event, distinct_id, properties \\ %{}, opts \\ [])
      when is_binary(event) and is_binary(distinct_id) do
    enabled_dispatch(fn ->
      props =
        properties
        |> compact()
        |> Map.merge(%{
          "distinct_id" => distinct_id,
          "time" => System.system_time(:second),
          # Dedup token for at-least-once ingestion on retry — a fresh
          # UUID, not a DB id (Mixpanel allows `[a-zA-Z0-9-]`).
          "$insert_id" => Ecto.UUID.generate()
        })
        |> put_present("$device_id", opts[:device_id], blank: @blanks)
        |> put_present("$user_id", opts[:user_id], blank: @blanks)
        |> put_present("ip", opts[:ip], blank: @blanks)

      MixpanelClient.track([%{"event" => event, "properties" => props}])
    end)
  end

  @doc """
  Set/update a user profile (`/engage $set`). Only ever for an identified
  user. `$ip: "0"` suppresses geo on the profile — operator IPs are not
  analytics fodder.
  """
  @spec set_people(String.t(), map(), keyword()) :: :ok
  def set_people(distinct_id, set_properties, opts \\ []) when is_binary(distinct_id) do
    enabled_dispatch(fn ->
      update =
        %{"$distinct_id" => distinct_id, "$ip" => "0", "$set" => compact(set_properties)}
        |> put_present("$set_once", opts[:set_once] && compact(opts[:set_once]), blank: @blanks)

      MixpanelClient.engage([update])
    end)
  end

  @doc """
  Set a Mixpanel Group profile. Gated by `:mixpanel_groups_enabled`
  (default off) — Group Analytics is a paid add-on, so we never
  hard-depend on it; `account_id` rides every event as a plain property
  regardless.
  """
  @spec set_group(String.t(), String.t(), map(), keyword()) :: :ok
  def set_group(group_key, group_id, set_properties, _opts \\ [])
      when is_binary(group_key) and is_binary(group_id) do
    if groups_enabled?() do
      enabled_dispatch(fn ->
        MixpanelClient.set_groups([
          %{
            "$group_key" => group_key,
            "$group_id" => group_id,
            "$set" => compact(set_properties)
          }
        ])
      end)
    end

    :ok
  end

  # -- internals -------------------------------------------------------

  defp enabled_dispatch(fun) do
    if enabled?(), do: dispatch(fun)
    :ok
  end

  # Fire-and-forget on the shared web Task.Supervisor (drained on
  # SIGTERM). `:analytics_async?` is forced false in test so the
  # client's stub send/2 lands in the test process. Mirrors
  # `Approvals.run_notify/1`.
  defp dispatch(fun) do
    if Application.get_env(:emisar, :analytics_async?, true) do
      supervisor = Application.fetch_env!(:emisar, :task_supervisor)
      Task.Supervisor.start_child(supervisor, fun)
    else
      fun.()
    end
  end

  @doc "Whether analytics is live (prod with a `MIXPANEL_TOKEN`). Off ⇒ everything no-ops."
  def enabled?, do: Application.get_env(:emisar, :mixpanel_enabled, false)

  defp groups_enabled?, do: Application.get_env(:emisar, :mixpanel_groups_enabled, false)

  # Omit absent properties entirely — Mixpanel guidance: never send null
  # or "". Keeps numbers/booleans (incl. `false`/`0`), drops nil + "".
  defp compact(map) do
    Map.reject(map, fn {_k, v} -> v in @blanks end)
  end
end
