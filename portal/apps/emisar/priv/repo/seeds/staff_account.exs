defmodule Emisar.Seeds.StaffAccount do
  @moduledoc """
  The development staff login for `/admin`, created the way production creates
  one: `Emisar.Release.create_staff/1`, which prints the authenticator key once.

  A reseed keeps an existing staff login and its key, so the authenticator entry
  a developer added keeps working. The emailed half of the sign-in lands in the
  dev mailbox. A lost key is `Emisar.Release.reset_staff/1`, as in production.
  """

  alias Emisar.Admin
  alias Emisar.Seeds.Helpers

  @email "admin@emisar.dev"

  def run do
    if Enum.any?(Admin.list_staff(), &(&1.email == @email)) do
      Helpers.say("✓ Staff login #{@email} kept (sign in at /admin/sign_in)")
    else
      :ok = Emisar.Release.create_staff(@email)
    end
  end
end
