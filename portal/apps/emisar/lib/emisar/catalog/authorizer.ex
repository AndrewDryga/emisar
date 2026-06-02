defmodule Emisar.Catalog.Authorizer do
  @moduledoc "Authorization for the action / pack catalogue."
  use Emisar.Auth.Authorizer

  alias Emisar.Catalog.{PackVersion, RunnerAction}

  def view_catalog_permission, do: build(RunnerAction, :view)

  # Pack trust mutations — Trust / Reject a pending pack-version hash.
  # Owners + admins only; an unprivileged operator shouldn't be able
  # to silently flip a tampered pack into a trusted state.
  def manage_catalog_permission, do: build(PackVersion, :manage)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin],
    do: [view_catalog_permission(), manage_catalog_permission()]

  def list_permissions_for_role(role) when role in [:operator, :viewer],
    do: [view_catalog_permission()]

  def list_permissions_for_role(:api_client),
    do: [view_catalog_permission()]

  def list_permissions_for_role(:runner),
    do: [view_catalog_permission()]

  def list_permissions_for_role(:system),
    do: [view_catalog_permission(), manage_catalog_permission()]

  def list_permissions_for_role(_), do: []

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{actor: :system}), do: queryable

  def for_subject(queryable, %Subject{account: %{id: account_id}}) do
    case query_source(queryable) do
      :runner_actions -> RunnerAction.Query.by_account_id(queryable, account_id)
      :pack_versions -> PackVersion.Query.by_account_id(queryable, account_id)
      _ -> queryable
    end
  end

  def for_subject(queryable, _), do: queryable

  defp query_source(%Ecto.Query{from: %{source: {table, _}}}), do: String.to_atom(table)
  defp query_source(_), do: nil
end
