defmodule Emisar.Auth.Authorizer do
  @moduledoc """
  Behaviour every `<Context>.Authorizer` implements. Two responsibilities:

    * the permission catalogue (`list_permissions_for_role/1`) — which
      `{module, action}` tuples a role/actor-kind holds;
    * scoping (`for_subject/2`) — narrow a queryable to what the supplied
      subject is allowed to see.

  Public-context entry points are expected to:

      with :ok <- Auth.Authorizer.ensure_has_permissions(subject, ...) do
        Entity.Query.not_deleted()
        |> ContextAuthorizer.for_subject(subject)
        |> Repo.fetch(Entity.Query, opts)
      end
  """

  alias Emisar.Auth.Subject

  @type permission :: {module(), atom()}

  @callback list_permissions_for_role(Subject.role()) :: [permission()]
  @callback for_subject(Ecto.Queryable.t(), Subject.t()) :: Ecto.Queryable.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour Emisar.Auth.Authorizer
      alias Emisar.Auth.Subject

      import Emisar.Auth.Authorizer, only: [build: 2, has_permission?: 2, query_source: 1]
    end
  end

  @doc "Convenience constructor for a permission tuple."
  def build(module, action), do: {module, action}

  def has_permission?(%Subject{permissions: perms}, permission),
    do: MapSet.member?(perms, permission)

  @doc """
  The base table of a queryable as an atom (e.g. `:action_runs`), or `nil`
  when it can't be determined. `for_subject/2` implementations use it to
  apply a table-specific scope only when the query actually targets that
  table — a joined or label-selecting query must not get the row filter.
  """
  def query_source(%Ecto.Query{from: %{source: {table, _}}}), do: String.to_atom(table)
  def query_source(_), do: nil

  @doc """
  Top-level gate. Returns `:ok` if the subject holds every required
  permission, `{:error, :unauthorized}` otherwise. Supports
  `{:one_of, [perm, ...]}` shorthand.
  """
  def ensure_has_permissions(%Subject{} = subject, {:one_of, perms}) when is_list(perms) do
    if Enum.any?(perms, &has_permission?(subject, &1)),
      do: :ok,
      else: {:error, :unauthorized}
  end

  def ensure_has_permissions(%Subject{} = subject, perm) when is_tuple(perm) do
    if has_permission?(subject, perm),
      do: :ok,
      else: {:error, :unauthorized}
  end

  def ensure_has_permissions(%Subject{} = subject, perms) when is_list(perms) do
    if Enum.all?(perms, &has_permission?(subject, &1)),
      do: :ok,
      else: {:error, :unauthorized}
  end

  # -- Permission catalogue -------------------------------------------

  @authorizers [
    Emisar.Accounts.Authorizer,
    Emisar.ApiKeys.Authorizer,
    Emisar.Approvals.Authorizer,
    Emisar.Audit.Authorizer,
    Emisar.Billing.Authorizer,
    Emisar.Catalog.Authorizer,
    Emisar.Policies.Authorizer,
    Emisar.Runbooks.Authorizer,
    Emisar.Runners.Authorizer,
    Emisar.Runs.Authorizer
  ]

  @doc """
  Returns the full permission set for a role. Unions every authorizer's
  `list_permissions_for_role/1`. `:system` is the all-rights shortcut
  for cron workers + seeds.
  """
  def permissions_for(role) when is_atom(role) do
    @authorizers
    |> Enum.flat_map(fn mod ->
      if Code.ensure_loaded?(mod) and function_exported?(mod, :list_permissions_for_role, 1) do
        mod.list_permissions_for_role(role)
      else
        []
      end
    end)
    |> MapSet.new()
  end

  def permissions_for(_), do: MapSet.new()

  @doc """
  True when `subject` already holds every permission `role` grants — so it
  can assign that role, or act on a member who has it, without escalating
  beyond its own privileges. The permission-subset generalization of
  role-name guards like "only an owner can manage owners": no role
  hierarchy, just `permissions_for(role) ⊆ subject.permissions`. Robust to a
  non-nested permission model in a way a `== :owner` check is not.
  """
  def covers_role?(%Subject{permissions: perms}, role),
    do: MapSet.subset?(permissions_for(role), perms)
end
