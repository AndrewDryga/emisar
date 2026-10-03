defmodule Emisar.Fixtures.Admin do
  @moduledoc """
  Staff login fixtures. Production creates staff only through the
  `Emisar.Release` box commands; tests create them through the same
  `Emisar.Admin.create_staff/1`, so the row keeps its real shape.
  """
  alias Emisar.{Admin, Crypto, Fixtures, Repo}

  @doc "A staff login. Its `mfa_secret` is on the struct for `totp_code/2`."
  def create_staff(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    {:ok, staff, _secret} = Admin.create_staff(attrs[:email] || Fixtures.Random.unique_email())
    staff
  end

  @doc """
  A signed-in session for `staff`, minted directly rather than through the
  sign-in. Returns `{raw_token, %Admin.StaffToken{}}` with the staff preloaded.
  `:expires_at` overrides the 12-hour expiry.
  """
  def create_staff_session(%Admin.Staff{} = staff, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    {raw, digest} = Crypto.session_token()
    expires_at = attrs[:expires_at] || DateTime.add(DateTime.utc_now(), 12, :hour)

    session =
      staff
      |> Admin.StaffToken.Changeset.session(digest, expires_at)
      |> Repo.insert!()

    {raw, %{session | staff: staff}}
  end

  @doc "The current authenticator code for `staff`, never one about to go stale."
  def totp_code(%Admin.Staff{mfa_secret: secret}), do: Fixtures.Auth.totp_code(secret)

  @doc "Sets columns on a staff row directly (a failure count, a replay stamp)."
  def update_staff(%Admin.Staff{} = staff, changes) do
    staff |> Ecto.Changeset.change(changes) |> Repo.update!()
  end

  @doc "Sets columns on a staff token directly (an expiry, an attempt budget)."
  def update_staff_token(%Admin.StaffToken{} = token, changes) do
    token |> Ecto.Changeset.change(changes) |> Repo.update!()
  end
end
