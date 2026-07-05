defmodule Emisar.Audit.Authorizer do
  @moduledoc "Authorization for the audit log."
  use Emisar.Auth.Authorizer
  alias Emisar.Audit.Event

  def view_audit_permission, do: build(Event, :view)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin, :operator, :viewer],
    do: [view_audit_permission()]

  # API clients can view audit; the controller gates the key KIND
  # (`:audit_export`) so only a log-shipping token — not an MCP key — reaches
  # `/api/audit`. The role-level permission only opens the door.
  def list_permissions_for_role(:api_client),
    do: [view_audit_permission()]

  def list_permissions_for_role(:runner), do: []

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Event.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: queryable
end
