defmodule Emisar.PubSub do
  @moduledoc """
  Thin wrapper over Phoenix.PubSub for the broadcasts the LiveView UI
  subscribes to. Topics are namespaced so cross-account leakage is
  impossible by construction.

  Topic shapes:

    "account:<id>:runners"     — runner connect/disconnect/state
    "account:<id>:runs"        — run create/transition
    "account:<id>:approvals"   — approval requests / decisions
    "run:<id>"                 — per-run events (progress chunks)
    "runner:<id>"              — per-runner transport messages
  """

  alias Emisar.Runs.{ActionRun, RunEvent}
  alias Emisar.Runners.Runner
  alias Emisar.Approvals.Request

  @pubsub Emisar.PubSub.Server

  # -- Topics -----------------------------------------------------------

  def topic_for_account_runners(account_id), do: "account:#{account_id}:runners"
  def topic_for_account_runs(account_id), do: "account:#{account_id}:runs"
  def topic_for_account_approvals(account_id), do: "account:#{account_id}:approvals"
  def topic_for_run(run_id), do: "run:#{run_id}"
  def topic_for_runner(runner_id), do: "runner:#{runner_id}"

  # -- Subscribing ------------------------------------------------------

  def subscribe_account_runners(account_id),
    do: Phoenix.PubSub.subscribe(@pubsub, topic_for_account_runners(account_id))

  def subscribe_account_runs(account_id),
    do: Phoenix.PubSub.subscribe(@pubsub, topic_for_account_runs(account_id))

  def subscribe_account_approvals(account_id),
    do: Phoenix.PubSub.subscribe(@pubsub, topic_for_account_approvals(account_id))

  def subscribe_run(run_id), do: Phoenix.PubSub.subscribe(@pubsub, topic_for_run(run_id))
  def subscribe_runner(runner_id), do: Phoenix.PubSub.subscribe(@pubsub, topic_for_runner(runner_id))

  # -- Broadcasting -----------------------------------------------------

  def broadcast_runner(%Runner{} = runner, msg \\ :runner_updated) do
    payload = {msg, runner}
    Phoenix.PubSub.broadcast(@pubsub, topic_for_runner(runner.id), payload)
    Phoenix.PubSub.broadcast(@pubsub, topic_for_account_runners(runner.account_id), payload)
  end

  def broadcast_run(%ActionRun{} = run) do
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
  Cloud → runner: tell the per-runner socket process there's a new
  outbound message to deliver. The socket process (in
  `EmisarApi.RunnerSocket`) listens on `topic_for_runner/1`.
  """
  def deliver_to_runner(runner_id, msg) do
    Phoenix.PubSub.broadcast(@pubsub, topic_for_runner(runner_id), {:cloud_to_runner, msg})
  end
end
