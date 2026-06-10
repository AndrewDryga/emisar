defmodule Emisar.Runbooks.Authorizer do
  @moduledoc "Authorization for cloud runbooks."
  use Emisar.Auth.Authorizer
  alias Emisar.Runbooks.Runbook

  def manage_runbooks_permission, do: build(Runbook, :manage)
  def view_runbooks_permission, do: build(Runbook, :view)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin],
    do: [manage_runbooks_permission(), view_runbooks_permission()]

  def list_permissions_for_role(:operator),
    do: [view_runbooks_permission()]

  def list_permissions_for_role(:viewer),
    do: [view_runbooks_permission()]

  def list_permissions_for_role(:api_client),
    do: [view_runbooks_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Runbook.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: queryable
end
