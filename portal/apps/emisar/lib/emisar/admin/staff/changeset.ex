defmodule Emisar.Admin.Staff.Changeset do
  use Emisar, :changeset
  alias Emisar.Admin.Staff

  @doc "A new staff login with its authenticator secret."
  def create(email, secret) when is_binary(email) and is_binary(secret) do
    %Staff{}
    |> cast(%{email: email}, [:email])
    |> update_change(:email, &String.trim/1)
    |> validate_required([:email])
    |> Emisar.EmailAddress.validate(:email)
    |> put_change(:mfa_secret, secret)
    |> unique_constraint(:email)
  end

  @doc "A new authenticator secret; the replay stamp and the failure count start over."
  def reset(%Staff{} = staff, secret) when is_binary(secret),
    do: change(staff, mfa_secret: secret, mfa_last_used_at: nil, failed_mfa_attempts: 0)

  @doc "A completed sign-in: consumes the TOTP bucket and clears the failure count."
  def signed_in(%Staff{} = staff, %DateTime{} = at),
    do: change(staff, mfa_last_used_at: at, failed_mfa_attempts: 0)

  @doc "One more wrong authenticator code after a correct emailed code."
  def mfa_failed(%Staff{failed_mfa_attempts: count} = staff) when is_integer(count) do
    staff
    |> change(failed_mfa_attempts: count + 1)
    |> check_constraint(:failed_mfa_attempts, name: :admin_staff_failed_mfa_attempts_check)
  end
end
