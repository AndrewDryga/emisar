defmodule Emisar.Runners.Token.Changeset do
  @moduledoc """
  Changesets for per-runner tokens — the long-lived credential a runner
  persists at `${data_dir}/token` and presents on every reconnect.
  """
  use Emisar, :changeset
  alias Emisar.Runners.Token

  def create(runner_id, issued_via_key_id, prefix, hash, opts \\ [])
      when is_binary(runner_id) do
    now = DateTime.utc_now()
    # nil keeps the historical never-expires behaviour. Callers that mint a
    # rotatable token pass a lifetime; the ones that cannot yet (an offline
    # bootstrap, a test fixture pinning old shape) simply do not.
    expires_at =
      case Keyword.get(opts, :lifetime_seconds) do
        seconds when is_integer(seconds) and seconds > 0 -> DateTime.add(now, seconds, :second)
        _ -> nil
      end

    %Token{}
    |> cast(
      %{
        runner_id: runner_id,
        token_prefix: prefix,
        token_hash: hash,
        issued_via_key_id: issued_via_key_id,
        issued_at: now,
        expires_at: expires_at
      },
      [:runner_id, :token_prefix, :token_hash, :issued_via_key_id, :issued_at, :expires_at]
    )
    |> validate_required([:runner_id, :token_prefix, :token_hash, :issued_at])
  end

  def usage(%Token{} = token), do: change(token, last_used_at: DateTime.utc_now())

  @doc """
  Internal — `Runners.refresh_runner_token/2`: retire the outgoing token once
  its successor has been minted. Expiry rather than deletion, so a runner that
  never receives or never persists the successor keeps a working credential for
  the grace window instead of being locked out by its own refresh.
  """
  def retire_after(%Token{} = token, grace_seconds) when is_integer(grace_seconds) do
    change(token, expires_at: DateTime.add(DateTime.utc_now(), grace_seconds, :second))
  end
end
