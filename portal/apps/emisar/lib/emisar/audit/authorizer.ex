defmodule Emisar.Audit.Authorizer do
  @moduledoc "Authorization for the audit log."
  use Emisar.Auth.Authorizer
  alias Emisar.Audit.Event

  def view_audit_permission, do: build(Event, :view)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin, :operator, :viewer],
    do: [view_audit_permission()]

  # API clients can view audit when their key carries the `audit:read`
  # scope; the controller is responsible for the scope gate. The role-
  # level permission only opens the door — the per-key `scopes` array
  # decides whether THIS key gets through it.
  def list_permissions_for_role(:api_client),
    do: [view_audit_permission()]

  def list_permissions_for_role(:runner), do: []

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Event.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: queryable
end
