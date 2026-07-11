defmodule Emisar.Runbooks.Authorizer do
  @moduledoc "Authorization for cloud runbooks."
  use Emisar.Auth.Authorizer
  alias Emisar.Runbooks.Runbook

  def manage_runbooks_permission, do: build(Runbook, :manage)
  def draft_runbooks_permission, do: build(Runbook, :draft)
  def view_runbooks_permission, do: build(Runbook, :view)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin],
    do: [manage_runbooks_permission(), view_runbooks_permission()]

  def list_permissions_for_role(:operator),
    do: [view_runbooks_permission()]

  def list_permissions_for_role(:viewer),
    do: [view_runbooks_permission()]

  # MCP keys authenticate as :api_client, and the MCP surface lets an LLM draft
  # a runbook for operator review (`create_runbook_draft`). It gets the narrow
  # `draft` permission — `create_runbook` accepts manage OR draft — but NOT
  # `manage`, so publish / save-version / delete stay closed to it at the DOMAIN
  # layer, not merely by which tools the MCP wiring happens to expose today.
  def list_permissions_for_role(:api_client),
    do: [draft_runbooks_permission(), view_runbooks_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Runbook.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: queryable
end
