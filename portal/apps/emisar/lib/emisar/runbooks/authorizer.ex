defmodule Emisar.Runbooks.Authorizer do
  @moduledoc "Authorization for cloud runbooks."
  use Emisar.Auth.Authorizer
  alias Emisar.Runbooks.{Runbook, RunbookExecution}

  # Lifecycle — deleting a runbook. Owners and admins only: a delete ends the
  # record of an approved procedure, which is not an authoring act.
  def manage_runbooks_permission, do: build(Runbook, :manage)

  # Authoring — create, save the draft, publish it, discard it. Operators hold
  # this, bounded by their own runner and pack access (the mutations judge every
  # step against it). Deliberately NOT held by `:api_client`: publication is
  # human-only, and a model's draft writes go through the operation-reserved
  # `create_or_replay_mcp_draft*` paths, never `save_draft/4`.
  def author_runbooks_permission, do: build(Runbook, :author)

  def draft_runbooks_permission, do: build(Runbook, :draft)
  def view_runbooks_permission, do: build(Runbook, :view)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin],
    do: [
      manage_runbooks_permission(),
      author_runbooks_permission(),
      view_runbooks_permission()
    ]

  def list_permissions_for_role(:operator),
    do: [author_runbooks_permission(), view_runbooks_permission()]

  def list_permissions_for_role(:viewer),
    do: [view_runbooks_permission()]

  # MCP keys authenticate as :api_client, and the MCP surface lets an LLM draft
  # a runbook for operator review (`create_runbook_draft`). It gets the narrow
  # `draft` permission — `create_runbook` accepts author OR draft — but neither
  # `author` nor `manage`, so publish / save-draft / discard / delete stay
  # closed to it at the DOMAIN layer, not merely by which tools the MCP wiring
  # happens to expose today.
  def list_permissions_for_role(:api_client),
    do: [draft_runbooks_permission(), view_runbooks_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{account: %{id: account_id}}) do
    case query_source(queryable) do
      :runbooks -> Runbook.Query.by_account_id(queryable, account_id)
      :runbook_executions -> RunbookExecution.Query.by_account_id(queryable, account_id)
      _ -> Runbook.Query.none(queryable)
    end
  end

  def for_subject(queryable, _), do: Runbook.Query.none(queryable)
end
