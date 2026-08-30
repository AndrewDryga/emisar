defmodule EmisarWeb.SchemaController do
  @moduledoc """
  Serves the published, immutable JSON Schemas whose `$id` points at this host,
  so an authoring tool (or a `$ref`-resolving validator) can fetch the canonical
  URL the schema names for itself. Machine-facing JSON on the `:api` pipeline —
  no session, CSRF, CSP, or analytics a document fetch has no use for.
  """
  use EmisarWeb, :controller
  alias Emisar.Runbooks

  @doc """
  The v1 runbook-definition schema, at the `$id` it declares
  (`/schemas/runbook-definition-v1.json`). A new schema version ships at a new
  URL, so this one is immutable and cached for a year.
  """
  def runbook_definition_v1(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> json(Runbooks.definition_schema())
  end
end
