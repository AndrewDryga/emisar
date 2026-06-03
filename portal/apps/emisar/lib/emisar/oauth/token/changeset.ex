defmodule Emisar.OAuth.Token.Changeset do
  use Emisar, :changeset
  alias Emisar.OAuth.Token

  @cast_fields ~w(access_token_hash refresh_token_hash client_id account_id
                  membership_id api_key_id scope resource
                  access_expires_at refresh_expires_at)a

  @required ~w(access_token_hash client_id account_id api_key_id access_expires_at)a

  @doc """
  Create an issued token pair. The caller has hashed the raw tokens and
  computed expiries; this casts + persists. `refresh_token_hash` +
  `refresh_expires_at` are nil when `offline_access` wasn't granted.
  """
  def create(attrs) do
    %Token{}
    |> cast(attrs, @cast_fields)
    |> validate_required(@required)
  end

  @doc "Revoke a token row (used on refresh-token rotation)."
  def revoke(%Token{} = token) do
    change(token, revoked_at: DateTime.utc_now())
  end
end
