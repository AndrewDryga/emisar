defmodule Emisar.Auth.ContextAuthorizer do
  @moduledoc """
  Behaviour every `<Context>.Authorizer` implements, plus the permission
  builders it uses. Two responsibilities:

    * the permission catalogue (`list_permissions_for_role/1`) — which
      `{module, action}` tuples a role/actor-kind holds;
    * scoping (`for_subject/2`) — narrow a queryable to what the supplied
      subject is allowed to see.

  Every context authorizer depends on this module at compile time, so it must
  not reach any context at runtime. The live authorization gate that re-reads
  session authority is `Emisar.Auth.Authorizer`.
  """

  @type permission :: {module(), atom()}

  @callback list_permissions_for_role(Emisar.Auth.Subject.role()) :: [permission()]
  @callback for_subject(Ecto.Queryable.t(), Emisar.Auth.Subject.t()) :: Ecto.Queryable.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour Emisar.Auth.ContextAuthorizer
      alias Emisar.Auth.Subject
      import Emisar.Auth.ContextAuthorizer, only: [build: 2, has_permission?: 2, query_source: 1]
    end
  end

  @doc "Convenience constructor for a permission tuple."
  def build(module, action), do: {module, action}

  @doc "Whether the subject's permission set holds `permission`. Pure."
  def has_permission?(%{permissions: perms}, permission), do: MapSet.member?(perms, permission)

  @doc """
  The base table of a queryable as an atom (e.g. `:action_runs`), or `nil`
  when it can't be determined. `for_subject/2` implementations use it to
  apply a table-specific scope only when the query actually targets that
  table — a joined or label-selecting query must not get the row filter.
  """
  # `table` is a compile-time schema source (our own migrations name the
  # tables), so the atom always exists — to_existing_atom keeps IL-14's
  # no-atom-minting guarantee without a whitelist.
  def query_source(%Ecto.Query{from: %{source: {table, _}}}),
    do: String.to_existing_atom(table)

  def query_source(_), do: nil
end
