defmodule Emisar.PubSub do
  @moduledoc """
  Shared Phoenix.PubSub plumbing. Topic *names*, subscriptions, and
  broadcasts are owned by the domain contexts (`Runs.subscribe_account_runs/1`,
  `Approvals.subscribe_account_approvals/1`, …) — this module only knows the
  server and the raw operations they compose.

  Account-domain topics are `account:<id>:`-prefixed, including per-run and
  per-runner topics. The prefix partitions delivery; it is not authorization.
  Domain subscription helpers must derive the account id from an already
  authorized subject or resource. Session, SSO-link, Presence, and process-drain
  topics use their own narrowly owned naming schemes.
  """
  @pubsub Emisar.PubSub.Server

  def subscribe(topic) when is_binary(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)

  def unsubscribe(topic) when is_binary(topic), do: Phoenix.PubSub.unsubscribe(@pubsub, topic)

  # Normalized to :ok so the per-event broadcast_* functions satisfy the
  # `after_commit` callback contract without each appending a bare :ok.
  # Broadcasts are fire-and-forget; no caller branches on delivery.
  def broadcast(topic, payload) when is_binary(topic) do
    _ = Phoenix.PubSub.broadcast(@pubsub, topic, payload)
    :ok
  end
end
