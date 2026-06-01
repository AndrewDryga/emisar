defmodule EmisarWeb.Mcp.Idempotency do
  @moduledoc """
  MCP idempotency-key handling. Two layers:

    * Layer 1 (transport): the MCP bridge auto-mints an `Idempotency-Key`
      HTTP header per JSON-RPC call so a re-sent identical call collapses
      to the original run. Invisible to the LLM.

    * Layer 2 (model intent): the `idempotency_key` tool arg lets the LLM
      itself opt into at-most-once semantics on a deliberate retry.
      Wins over Layer 1 because the model knows its own retry intent.

  Both sources are sanitised identically (trim, non-empty, length-capped
  at #{200} bytes) so a chatty / buggy client can't fill the unique index
  with garbage or accidentally request replay semantics by sending an
  empty string.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @max_length 200

  @doc """
  Returns the idempotency key for this call, applying Layer 2 → Layer 1
  precedence. `nil` means "no replay semantics" — the dispatch proceeds
  fresh.
  """
  def resolve(conn, params) do
    case sanitize(params["idempotency_key"]) do
      nil -> read_header(conn)
      key -> key
    end
  end

  @doc """
  Suffixes the caller's key with the runner id for an N-runner fan-out
  so each runner's row claims a distinct slot in the
  `(api_key_id, idempotency_key)` unique index. A retry with the same
  runner set replays each row individually.

  Returns `nil` when there's no key — callers store the result directly
  on the run, and `nil` skips the unique index (the partial index is
  `where idempotency_key IS NOT NULL`).
  """
  def per_runner(nil, _runner_id), do: nil
  def per_runner(key, runner_id), do: key <> ":" <> runner_id

  defp read_header(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key | _] -> sanitize(key)
      _ -> nil
    end
  end

  defp sanitize(key) when is_binary(key) do
    trimmed = String.trim(key)
    if trimmed != "" and byte_size(trimmed) <= @max_length, do: trimmed, else: nil
  end

  defp sanitize(_), do: nil
end
