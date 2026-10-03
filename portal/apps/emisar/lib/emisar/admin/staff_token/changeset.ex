defmodule Emisar.Admin.StaffToken.Changeset do
  use Emisar, :changeset
  alias Emisar.Admin.{Staff, StaffToken}

  @doc "A pending sign-in code: the digest of `nonce <> code` with its guess budget."
  def sign_in(%Staff{id: staff_id}, digest, attempts, %DateTime{} = expires_at)
      when is_binary(digest) and is_integer(attempts) and attempts > 0 do
    change(%StaffToken{},
      staff_id: staff_id,
      context: :sign_in,
      token: digest,
      remaining_attempts: attempts,
      expires_at: expires_at
    )
  end

  @doc "A signed-in session: the digest of the raw cookie value."
  def session(%Staff{id: staff_id}, digest, %DateTime{} = expires_at) when is_binary(digest) do
    change(%StaffToken{},
      staff_id: staff_id,
      context: :session,
      token: digest,
      expires_at: expires_at
    )
  end

  @doc "A failed attempt against a sign-in code."
  def spend_attempt(%StaffToken{context: :sign_in, remaining_attempts: attempts} = token)
      when is_integer(attempts) and attempts > 0 do
    token
    |> change(remaining_attempts: attempts - 1)
    |> check_constraint(:remaining_attempts,
      name: :admin_staff_tokens_remaining_attempts_check
    )
  end
end
