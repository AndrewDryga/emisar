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
  alias Emisar.Auth.{SessionGrants, Subject}
  alias Emisar.Users

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
  # `table` is a compile-time schema source (our own migrations name the
  # tables), so the atom always exists — to_existing_atom keeps IL-14's
  # no-atom-minting guarantee without a whitelist.
  def query_source(%Ecto.Query{from: %{source: {table, _}}}),
    do: String.to_existing_atom(table)

  def query_source(_), do: nil

  @doc """
  Top-level gate. Returns `:ok` if the subject holds every required
  permission, `{:error, :unauthorized}` otherwise. Supports
  `{:one_of, [perm, ...]}` shorthand.
  """
  def ensure_has_permissions(%Subject{} = subject, required) do
    case fetch_authorized_subject(subject, required) do
      {:ok, _current} -> :ok
      {:error, :unauthorized} = error -> error
    end
  end

  @doc "Internal — return the same freshly resolved authority whose permissions and policy passed."
  def fetch_authorized_subject(%Subject{} = subject, required) do
    with {:ok, current} <- fetch_addressable_subject(subject, required),
         :ok <- ensure_session_compliant(current) do
      {:ok, current}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Internal — exact live authority for account selection and step-up, without authorizing protected work."
  def fetch_addressable_subject(%Subject{} = subject, required) do
    with true <- holds_permissions?(subject, required),
         {:ok, current} <- current_authority(subject),
         true <- holds_permissions?(current, required) do
      {:ok, current}
    else
      _ -> {:error, :unauthorized}
    end
  end

  # Never lock here: contexts also call this gate while holding their own
  # resource locks. Mutation-specific fences own serialization; this read closes
  # held-Subject/reconnect access after a bearer, grant or Member is revoked.
  defp current_authority(%Subject{actor: %Users.User{}} = subject),
    do: SessionGrants.fetch_subject(subject)

  defp current_authority(%Subject{} = subject), do: {:ok, subject}

  defp ensure_session_compliant(%Subject{actor: %Users.User{}} = subject),
    do: Emisar.Accounts.account_compliance_for_session(subject.account, subject)

  defp ensure_session_compliant(%Subject{}), do: :ok

  defp holds_permissions?(subject, {:one_of, perms}) when is_list(perms),
    do: Enum.any?(perms, &has_permission?(subject, &1))

  defp holds_permissions?(subject, perm) when is_tuple(perm), do: has_permission?(subject, perm)

  defp holds_permissions?(subject, perms) when is_list(perms),
    do: Enum.all?(perms, &has_permission?(subject, &1))
end
