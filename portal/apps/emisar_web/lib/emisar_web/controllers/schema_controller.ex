defmodule EmisarWeb.SchemaController do
  @moduledoc """
  Serves the published JSON Schemas whose `$id` points at this host, so an
  authoring tool (or a `$ref`-resolving validator) can fetch the canonical URL
  the schema names for itself. Machine-facing JSON on the `:api` pipeline — no
  session, CSRF, CSP, or analytics a document fetch has no use for.
  """
  use EmisarWeb, :controller
  alias Emisar.Runbooks

  @doc """
  The v1 runbook-definition schema, at the `$id` it declares
  (`/schemas/runbook-definition-v1.json`). The v1 document still gains
  compatible clarifications in place, so caches keep it briefly and then
  revalidate against its content ETag. An INCOMPATIBLE change ships at a new
  URL: copies served under the old one-year `immutable` header can outlive any
  edit made here.
  """
  def runbook_definition_v1(conn, _params) do
    body = Jason.encode!(Runbooks.definition_schema())
    etag = ~s("#{Base.url_encode64(:crypto.hash(:sha256, body), padding: false)}")

    conn =
      conn
      |> put_resp_header("cache-control", "public, max-age=3600, must-revalidate")
      |> put_resp_header("etag", etag)

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
  end
end
