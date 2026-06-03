defmodule Emisar.OAuth.AuthorizationCode.Changeset do
  use Emisar, :changeset
  alias Emisar.OAuth.AuthorizationCode

  @cast_fields ~w(code_hash client_id account_id membership_id api_key_id
                  redirect_uri code_challenge code_challenge_method
                  scope resource expires_at)a

  @required ~w(code_hash client_id account_id api_key_id redirect_uri
               code_challenge expires_at)a

  @doc """
  Create a single-use authorization code. The caller has already hashed
  the raw code and computed the expiry; this casts + persists.
  """
  def create(attrs) do
    %AuthorizationCode{}
    |> cast(attrs, @cast_fields)
    |> validate_required(@required)
  end

  @doc "Burn the code — stamps `used_at` so it can never be exchanged twice."
  def consume(%AuthorizationCode{} = code) do
    change(code, used_at: DateTime.utc_now())
  end
end
