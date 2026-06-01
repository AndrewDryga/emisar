defmodule Emisar.Runners.Authorizer do
  @moduledoc """
  Permissions + queryable scoping for runner-related schemas: runners,
  auth keys, runner tokens, event cursors.

    * `manage_*` gates mutations and admin-only listings.
    * `view_runners_permission` gates read-only operator/viewer surfaces.
  """
  use Emisar.Auth.Authorizer

  alias Emisar.Runners.{AuthKey, EventCursor, Runner, Token}

  # -- Catalogue -------------------------------------------------------

  def manage_runners_permission, do: build(Runner, :manage)
  def view_runners_permission, do: build(Runner, :view)
  def issue_install_key_permission, do: build(AuthKey, :issue_install)
  def manage_auth_keys_permission, do: build(AuthKey, :manage)

  @impl Emisar.Auth.Authorizer
  def list_permissions_for_role(role) when role in [:owner, :admin],
    do: [
      manage_runners_permission(),
      view_runners_permission(),
      manage_auth_keys_permission(),
      issue_install_key_permission()
    ]

  def list_permissions_for_role(:operator),
    do: [view_runners_permission(), issue_install_key_permission()]

  def list_permissions_for_role(:viewer),
    do: [view_runners_permission()]

  def list_permissions_for_role(:api_client),
    do: [view_runners_permission()]

  def list_permissions_for_role(:runner), do: []

  def list_permissions_for_role(:system),
    do: [
      manage_runners_permission(),
      view_runners_permission(),
      manage_auth_keys_permission(),
      issue_install_key_permission()
    ]

  def list_permissions_for_role(_), do: []

  # -- Subject scoping -------------------------------------------------

  @impl Emisar.Auth.Authorizer
  def for_subject(queryable, %Subject{actor: :system}), do: queryable

  # Runner socket — narrow to the calling runner's own rows. Cross-runner
  # visibility within an account is intentionally impossible.
  def for_subject(queryable, %Subject{actor: %Runner{id: runner_id}}) do
    case query_source(queryable) do
      :runners -> Runner.Query.by_id(queryable, runner_id)
      :runner_tokens -> Token.Query.by_runner_id(queryable, runner_id)
      :runner_event_cursors -> EventCursor.Query.by_runner_id(queryable, runner_id)
      _ -> queryable
    end
  end

  def for_subject(queryable, %Subject{account: %{id: account_id}}) do
    case query_source(queryable) do
      :runners -> Runner.Query.by_account_id(queryable, account_id)
      :runner_auth_keys -> AuthKey.Query.by_account_id(queryable, account_id)
      :runner_tokens -> Token.Query.by_runner_account_id(queryable, account_id)
      :runner_event_cursors -> EventCursor.Query.by_runner_account_id(queryable, account_id)
      _ -> queryable
    end
  end

  def for_subject(queryable, _), do: queryable

  defp query_source(%Ecto.Query{from: %{source: {table, _}}}), do: String.to_atom(table)
  defp query_source(_), do: nil
end
