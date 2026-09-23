defmodule Emisar.Auth.Authorizer do
  @moduledoc """
  The live authorization gate. Public-context entry points are expected to:

      with :ok <- Auth.Authorizer.ensure_has_permissions(subject, ...) do
        Entity.Query.not_deleted()
        |> ContextAuthorizer.for_subject(subject)
        |> Repo.fetch(Entity.Query, opts)
      end

  Context authorizers implement `Emisar.Auth.ContextAuthorizer`, which they
  depend on at compile time. This module re-reads session authority at
  runtime, so no authorizer may `use` or import it.
  """
  alias Emisar.{Accounts, ApiKeys, Runners, Users}
  alias Emisar.Auth.{ContextAuthorizer, SessionGrants, Subject}

  defdelegate build(module, action), to: ContextAuthorizer
  defdelegate has_permission?(subject, permission), to: ContextAuthorizer
  defdelegate query_source(queryable), to: ContextAuthorizer

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
  # A person, linked to a personal login or not, is re-read through the bearer's
  # grant. API keys and runners are re-authenticated by their own boundary, and
  # the actorless support subject has no bearer. Any other actor is refused,
  # never treated as one of these.
  defp current_authority(%Subject{actor: %Users.User{}} = subject),
    do: SessionGrants.fetch_subject(subject)

  defp current_authority(%Subject{actor: %Accounts.Membership{}} = subject),
    do: SessionGrants.fetch_subject(subject)

  defp current_authority(%Subject{actor: %ApiKeys.ApiKey{}} = subject), do: {:ok, subject}
  defp current_authority(%Subject{actor: %Runners.Runner{}} = subject), do: {:ok, subject}
  defp current_authority(%Subject{actor: nil} = subject), do: {:ok, subject}
  defp current_authority(%Subject{}), do: {:error, :unauthorized}

  defp ensure_session_compliant(%Subject{actor: %Users.User{}} = subject),
    do: Accounts.account_compliance_for_session(subject.account, subject)

  defp ensure_session_compliant(%Subject{actor: %Accounts.Membership{}} = subject),
    do: Accounts.account_compliance_for_session(subject.account, subject)

  defp ensure_session_compliant(%Subject{actor: %ApiKeys.ApiKey{}}), do: :ok
  defp ensure_session_compliant(%Subject{actor: %Runners.Runner{}}), do: :ok
  defp ensure_session_compliant(%Subject{actor: nil}), do: :ok
  defp ensure_session_compliant(%Subject{}), do: {:error, :unauthorized}

  defp holds_permissions?(subject, {:one_of, perms}) when is_list(perms),
    do: Enum.any?(perms, &has_permission?(subject, &1))

  defp holds_permissions?(subject, perm) when is_tuple(perm), do: has_permission?(subject, perm)

  defp holds_permissions?(subject, perms) when is_list(perms),
    do: Enum.all?(perms, &has_permission?(subject, &1))
end
