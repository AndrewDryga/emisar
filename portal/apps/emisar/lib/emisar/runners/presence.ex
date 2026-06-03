defmodule Emisar.Runners.Presence do
  @moduledoc """
  Phoenix.Presence tracking of connected runner sockets, scoped per
  account. Presence — not the database — is the source of truth for
  "is this runner connected right now", and its metadata carries the
  runner's ephemeral state (`action_load`, last heartbeat) that dies
  with the socket.

  The public read/write surface is `Emisar.Runners` (`connect_runner/1`,
  `record_heartbeat/3`, `online?/2`, `connection_metas/1`); this module
  is just the tracker + its topic.
  """
  use Phoenix.Presence,
    otp_app: :emisar,
    pubsub_server: Emisar.PubSub.Server

  @doc "PubSub topic carrying this account's runner presence diffs."
  def topic(account_id), do: "presence:account:#{account_id}"
end
