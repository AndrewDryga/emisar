defmodule Emisar.Runners.Token.Changeset do
  @moduledoc """
  Changesets for per-runner tokens — the long-lived credential a runner
  persists at `${data_dir}/token` and presents on every reconnect.
  """
  use Emisar, :changeset
  alias Emisar.Runners.Token

  def create(runner_id, issued_via_key_id, prefix, hash) when is_binary(runner_id) do
    %Token{}
    |> cast(
      %{
        runner_id: runner_id,
        token_prefix: prefix,
        token_hash: hash,
        issued_via_key_id: issued_via_key_id,
        issued_at: DateTime.utc_now()
      },
      [:runner_id, :token_prefix, :token_hash, :issued_via_key_id, :issued_at]
    )
    |> validate_required([:runner_id, :token_prefix, :token_hash, :issued_at])
  end

  def usage(%Token{} = token), do: change(token, last_used_at: DateTime.utc_now())

  def revoke(%Token{} = token), do: change(token, revoked_at: DateTime.utc_now())
end
