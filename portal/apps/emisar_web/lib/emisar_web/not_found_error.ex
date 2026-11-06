defmodule EmisarWeb.NotFoundError do
  @moduledoc """
  Raised for a tenant-scope miss under `/app/:account_id_or_slug/…`: an id or
  slug that names no workspace, a workspace and session that don't agree, or a
  page target the subject can't reach. Carries `plug_status: 404` so Phoenix
  renders the 404 page. A known workspace this browser has no session for is
  not a miss: `EmisarWeb.UserAuth` sends the request to that workspace's sign-in.
  """
  defexception message: "Not Found", plug_status: 404
end
