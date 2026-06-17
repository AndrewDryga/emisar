defmodule EmisarWeb.NotFoundError do
  @moduledoc """
  Raised when a slugged tenant route (`/app/:account_id_or_slug/…`) resolves to
  no membership the requester holds. Carries `plug_status: 404` so Phoenix renders
  the 404 page — a non-member slug is indistinguishable from a nonexistent one
  (404, never 403, no tenant-existence leak; see `Accounts.fetch_membership_by_account_id_or_slug/2`).
  """
  defexception message: "Not Found", plug_status: 404
end
