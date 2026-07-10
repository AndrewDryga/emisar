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

  # MCP keys authenticate as :api_client, and the MCP surface lets an LLM draft
  # a runbook for operator review (`create_runbook_draft`). Drafting reuses the
  # manage-gated `create_runbook`, so api_client must carry manage. This is safe:
  # a draft is inert until an operator publishes it, and the MCP layer exposes
  # ONLY draft-create + execute — never publish/save-version/delete — so the
  # reachable capability is bounded to creating drafts.
  def list_permissions_for_role(:api_client),
    do: [manage_runbooks_permission(), view_runbooks_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}),
    do: Runbook.Query.by_account_id(queryable, account_id)

  def for_subject(queryable, _), do: queryable
end
