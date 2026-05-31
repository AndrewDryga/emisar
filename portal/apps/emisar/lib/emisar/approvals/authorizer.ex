defmodule Emisar.Approvals.Authorizer do
  @moduledoc "Authorization for approval requests + standing grants."
  use Emisar.Auth.Authorizer

  alias Emisar.Approvals.{Grant, Request}

  def decide_approval_permission, do: build(Request, :decide)
  def view_approvals_permission, do: build(Request, :view)
  def manage_grants_permission, do: build(Grant, :manage)
  def file_approval_permission, do: build(Request, :file)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin],
    do: [
      decide_approval_permission(),
      view_approvals_permission(),
      manage_grants_permission(),
      file_approval_permission()
    ]

  def list_permissions_for_role(:operator),
    do: [
      decide_approval_permission(),
      view_approvals_permission(),
      file_approval_permission()
    ]

  def list_permissions_for_role(:viewer),
    do: [view_approvals_permission()]

  def list_permissions_for_role(:api_client),
    do: [file_approval_permission()]

  def list_permissions_for_role(:system),
    do: [
      decide_approval_permission(),
      view_approvals_permission(),
      manage_grants_permission(),
      file_approval_permission()
    ]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{actor: :system}), do: queryable

  def for_subject(queryable, %Subject{account: %{id: account_id}}) do
    case query_source(queryable) do
      :approval_requests -> Request.Query.by_account_id(queryable, account_id)
      :approval_grants -> Grant.Query.by_account_id(queryable, account_id)
      _ -> queryable
    end
  end

  def for_subject(queryable, _), do: queryable

  defp query_source(%Ecto.Query{from: %{source: {table, _}}}), do: String.to_atom(table)
  defp query_source(_), do: nil
end
