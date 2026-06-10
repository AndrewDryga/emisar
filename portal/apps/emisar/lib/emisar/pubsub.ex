defmodule Emisar.PubSub do
  @moduledoc """
  Shared Phoenix.PubSub plumbing. Topic *names*, subscriptions, and
  broadcasts are owned by the domain contexts (`Runs.subscribe_account_runs/1`,
  `Approvals.subscribe_account_approvals/1`, …) — this module only knows the
  server and the raw operations they compose.

  Topic convention: everything is `account:<id>:`-prefixed (including the
  per-run and per-runner topics), so cross-account leakage is impossible by
  construction — a subscriber can only ever name topics inside its own
  account.
  """
  @pubsub Emisar.PubSub.Server

  @doc "The PubSub server name — for supervision/config wiring only."
  def server, do: @pubsub

  def subscribe(topic) when is_binary(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)

  def unsubscribe(topic) when is_binary(topic), do: Phoenix.PubSub.unsubscribe(@pubsub, topic)

  def broadcast(topic, payload) when is_binary(topic),
    do: Phoenix.PubSub.broadcast(@pubsub, topic, payload)
end
