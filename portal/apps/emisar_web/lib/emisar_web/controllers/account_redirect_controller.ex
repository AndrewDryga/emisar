defmodule EmisarWeb.AccountRedirectController do
  @moduledoc """
  Bare `/app` → the canonical slugged URL for the user's current account.

  `require_authenticated_user` has already run `assign_current_account/1`, which
  resolves the session-hinted (else default) membership — or bounces a
  no-membership user to onboarding / logs out a fully-suspended one. So by the
  time we get here `current_account` is set; we just forward to its slug.
  """
  use EmisarWeb, :controller

  def show(conn, _params) do
    redirect(conn, to: ~p"/app/#{conn.assigns.current_account}")
  end
end
