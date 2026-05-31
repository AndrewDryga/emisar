defmodule Emisar.Audit.Authorizer do
  @moduledoc "Authorization for the audit log."
  use Emisar.Auth.Authorizer

  alias Emisar.Audit.Event

  def view_audit_permission, do: build(Event, :view)
  def write_audit_permission, do: build(Event, :write)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin, :operator, :viewer],
    do: [view_audit_permission(), write_audit_permission()]

  def list_permissions_for_role(:api_client),
    do: [write_audit_permission()]

  def list_permissions_for_role(:runner),
    do: [write_audit_permission()]

  def list_permissions_for_role(:system),
    do: [view_audit_permission(), write_audit_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{actor: :system}), do: queryable

  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Event.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: queryable
end
