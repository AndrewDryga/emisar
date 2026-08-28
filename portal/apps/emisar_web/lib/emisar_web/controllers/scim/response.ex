defmodule EmisarWeb.SCIM.Response do
  @moduledoc """
  Owns the HTTP response contract shared by the SCIM controllers.

  Every route answers with the SCIM JSON media type. Resource creation also
  returns the canonical absolute resource URL in both the `Location` header and
  `meta.location`, so directory clients can follow the server-issued id without
  reconstructing our route.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]
  alias EmisarWeb.SCIM.Resource

  @content_type "application/scim+json"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: put_resp_content_type(conn, @content_type)

  @doc "Render a newly created User or Group with its canonical resource location."
  def created(conn, resource_type, id, resource) when is_binary(id) and is_map(resource) do
    location = resource_location(resource_type, id)
    resource = update_in(resource, ["meta"], &Map.put(&1, "location", location))

    conn
    |> call([])
    |> put_resp_header("location", location)
    |> put_status(:created)
    |> json(resource)
  end

  @doc "Render the fixed SCIM rate-limit error used before controller dispatch."
  def rate_limited(conn, retry_after) when is_integer(retry_after) do
    conn
    |> call([])
    |> put_status(:too_many_requests)
    |> json(Resource.error(429, "tooMany", "Too many requests. Retry in #{retry_after}s."))
  end

  @doc """
  Render the fixed SCIM error for a connection revoked mid-request.

  Authentication can succeed and an operator can then disable or delete the
  connection — or a plan downgrade can — before the mutation takes its
  provider-row fence. That is a revoked bearer at execution time, not a
  malformed payload, so it answers 401 with a `WWW-Authenticate` challenge.

  It lives here because both resource controllers meet the same cause and must
  give the same verdict. Groups had no clause for it and fell through to its
  `400 invalidValue` catch-all, so one revoked connection told an IdP two
  different things: Users said "fix the credential", Groups said "this object's
  payload is bad" — and an IdP answers that second one by marking the object
  errored and retrying forever with the same body.
  """
  def revoked(conn) do
    conn
    |> call([])
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_status(:unauthorized)
    |> json(
      Resource.error(401, "The SCIM bearer token is missing, malformed, or not authorized.")
    )
  end

  defp resource_location(:user, id), do: Emisar.PublicUrl.url("/scim/v2/Users/#{id}")
  defp resource_location(:group, id), do: Emisar.PublicUrl.url("/scim/v2/Groups/#{id}")
end
