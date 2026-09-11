defmodule Emisar.Seeds.StaffAccount do
  @moduledoc """
  The platform-admin persona for `/admin`, owning its OWN workspace rather than
  taking a seat in Northstar Labs: the demo accounts feed the docs screenshot
  captures, so their member lists must not grow a staff row. The workspace stays
  empty on purpose — it doubles as the empty-states surface.

  This is the ONE persona deliberately kept out of `clear_seeded_mfa`. `/admin`
  demands a second factor proved against the CURRENT enrollment, so a developer
  enrolls TOTP here once by hand, and a reseed must leave that enrollment — and
  the `is_admin` flag — standing rather than disabling it the way the screenshot
  personas need. The seed still never enrolls MFA nor mints a secret; that stays
  the human's step, walked by the gate itself.
  """

  alias Emisar.Repo
  alias Emisar.Seeds.Helpers
  alias Emisar.Users
  alias Emisar.Users.User

  @email "admin@emisar.dev"
  @full_name "Emisar Admin"

  def run do
    staff_user =
      case Users.fetch_user_by_email(@email) do
        {:error, :not_found} ->
          {:ok, registered} = Users.register_user(%{full_name: @full_name, email: @email})
          Helpers.confirm_user(registered)

        {:ok, %User{} = existing} ->
          existing |> Helpers.ensure_profile(@full_name) |> Helpers.confirm_user()
      end

    staff_user =
      if staff_user.is_admin do
        staff_user
      else
        # `is_admin` is a global platform flag no changeset casts and no context
        # writes — it is set out of band by design, so the seed builds the row itself.
        staff_user |> Ecto.Changeset.change(is_admin: true) |> Repo.update!()
      end

    _ = Helpers.ensure_account("Emisar Staff", "emisar-staff", staff_user)

    Helpers.say(
      "✓ Emisar Staff (slug=emisar-staff) — #{@email} is_admin; enroll TOTP once for /admin"
    )
  end
end
