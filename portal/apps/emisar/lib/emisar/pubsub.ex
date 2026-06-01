defmodule Emisar.PubSub do
  @moduledoc """
  Thin wrapper over Phoenix.PubSub for the broadcasts the LiveView UI
  subscribes to. Topics are namespaced so cross-account leakage is
  impossible by construction.

  Topic shapes:

    "account:<id>:runners"     — runner connect/disconnect/state
    "account:<id>:runs"        — run create/transition
    "account:<id>:approvals"   — approval requests / decisions
    "account:<id>:auth_keys"   — auth key issued / revoked / bound
    "account:<id>:api_keys"    — API key issued / revoked / bound
    "account:<id>:runbooks"    — runbook created / updated / published
    "account:<id>:team"        — membership invites / role changes / suspends
    "account:<id>:audit"       — fan-out: every audit row, for AuditLive
    "run:<id>"                 — per-run events (progress chunks)
    "runner:<id>"              — per-runner transport messages
  """

  alias Emisar.Runs.{ActionRun, RunEvent}
  alias Emisar.Runners.Runner
  alias Emisar.Approvals.Request
  alias Emisar.Audit.Event

  @pubsub Emisar.PubSub.Server

  # -- Topics -----------------------------------------------------------

  def topic_for_account_runners(account_id), do: "account:#{account_id}:runners"
  def topic_for_account_runs(account_id), do: "account:#{account_id}:runs"
  def topic_for_account_approvals(account_id), do: "account:#{account_id}:approvals"
  def topic_for_account_auth_keys(account_id), do: "account:#{account_id}:auth_keys"
  def topic_for_account_api_keys(account_id), do: "account:#{account_id}:api_keys"
  def topic_for_account_runbooks(account_id), do: "account:#{account_id}:runbooks"
  def topic_for_account_team(account_id), do: "account:#{account_id}:team"
  def topic_for_account_audit(account_id), do: "account:#{account_id}:audit"
  def topic_for_run(run_id), do: "run:#{run_id}"
  def topic_for_runner(runner_id), do: "runner:#{runner_id}"

  # -- Subscribing ------------------------------------------------------

  def subscribe_account_runners(account_id),
    do: Phoenix.PubSub.subscribe(@pubsub, topic_for_account_runners(account_id))

  def subscribe_account_runs(account_id),
    do: Phoenix.PubSub.subscribe(@pubsub, topic_for_account_runs(account_id))

  def subscribe_account_approvals(account_id),
    do: Phoenix.PubSub.subscribe(@pubsub, topic_for_account_approvals(account_id))

  def subscribe_account_auth_keys(account_id),
    do: Phoenix.PubSub.subscribe(@pubsub, topic_for_account_auth_keys(account_id))

  def subscribe_account_api_keys(account_id),
    do: Phoenix.PubSub.subscribe(@pubsub, topic_for_account_api_keys(account_id))

  def subscribe_account_runbooks(account_id),
    do: Phoenix.PubSub.subscribe(@pubsub, topic_for_account_runbooks(account_id))

  def subscribe_account_team(account_id),
    do: Phoenix.PubSub.subscribe(@pubsub, topic_for_account_team(account_id))

  def subscribe_account_audit(account_id),
    do: Phoenix.PubSub.subscribe(@pubsub, topic_for_account_audit(account_id))

  def subscribe_run(run_id), do: Phoenix.PubSub.subscribe(@pubsub, topic_for_run(run_id))
  def subscribe_runner(runner_id), do: Phoenix.PubSub.subscribe(@pubsub, topic_for_runner(runner_id))

  # -- Broadcasting -----------------------------------------------------

  def broadcast_runner(%Runner{} = runner, msg \\ :runner_updated) do
    payload = {msg, runner}
    Phoenix.PubSub.broadcast(@pubsub, topic_for_runner(runner.id), payload)
    Phoenix.PubSub.broadcast(@pubsub, topic_for_account_runners(runner.account_id), payload)
  end

  def broadcast_run(%ActionRun{} = run) do
    # Subscribers (RunDetailLive's meta strip, RunsLive table) need
    # `runner.name` to render — make `runner` preloaded part of the
    # payload contract so a `:run_updated` arriving after mount can
    # cleanly replace `@run` without re-introducing `%NotLoaded{}`.
    run =
      case run.runner do
        %Ecto.Association.NotLoaded{} -> Emisar.Repo.preload(run, :runner)
        _ -> run
      end

    payload = {:run_updated, run}
    Phoenix.PubSub.broadcast(@pubsub, topic_for_run(run.id), payload)
    Phoenix.PubSub.broadcast(@pubsub, topic_for_account_runs(run.account_id), payload)
  end

  def broadcast_run_event(%ActionRun{} = run, %RunEvent{} = event) do
    Phoenix.PubSub.broadcast(@pubsub, topic_for_run(run.id), {:run_event, event})
  end

  def broadcast_approval(%Request{} = req) do
    payload = {:approval_updated, req}
    Phoenix.PubSub.broadcast(@pubsub, topic_for_account_approvals(req.account_id), payload)
  end

  @doc """
  Generic per-domain "the list you're staring at just changed, reload"
  notification. Carries the changed entity id + the audit-style event
  type (e.g. `"auth_key.created"`) so a smart LV can do targeted patches
  later; today every subscriber just calls reload().

  Fired by the contexts inside their `commit_multi(after_commit: …)`
  block — only when the parent transaction actually commits, so a
  rolled-back mutation can't trick the UI into showing stale rows.
  """
  def broadcast_account_list(account_id, kind, event_type, entity_id) do
    payload = {:list_changed, kind, event_type, entity_id}

    topic =
      case kind do
        :auth_key -> topic_for_account_auth_keys(account_id)
        :api_key -> topic_for_account_api_keys(account_id)
        :runbook -> topic_for_account_runbooks(account_id)
        :team -> topic_for_account_team(account_id)
        :runner -> topic_for_account_runners(account_id)
      end

    Phoenix.PubSub.broadcast(@pubsub, topic, payload)
  end

  @doc """
  Fan-out audit broadcast. Fires the same `Audit.Event` row to the
  account-wide audit topic AND the per-domain topic the event
  semantically belongs to, so AuditLive gets every row and per-domain
  list LVs only need to subscribe to their own topic.
  """
  def broadcast_audit_event(%Event{} = event) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic_for_account_audit(event.account_id),
      {:audit_event, event}
    )
  end

  @doc """
  Cloud → runner: tell the per-runner socket process there's a new
  outbound message to deliver. The socket process (in
  `EmisarApi.RunnerSocket`) listens on `topic_for_runner/1`.
  """
  def deliver_to_runner(runner_id, msg) do
    Phoenix.PubSub.broadcast(@pubsub, topic_for_runner(runner_id), {:cloud_to_runner, msg})
  end
end
