defmodule Emisar.Auth.SessionSubject do
  @moduledoc false

  alias Emisar.{Accounts, Repo}
  alias Emisar.Auth.{Subject, UserToken}

  # The Authorizer's live re-read of a held Member Subject: the exact session it
  # acts through must still pass the per-request predicate for that same Member
  # in that same workspace. Revoking the session, removing or suspending the
  # Member, disabling the workspace or retiring the SSO route ends the Subject
  # at its next permission check. Permissions never widen past the held ones.
  def fetch(%Subject{} = subject) do
    with {:ok, session} <- fetch_session(subject) do
      current = Subject.for_session(session, subject.context)

      {:ok,
       %{current | permissions: MapSet.intersection(subject.permissions, current.permissions)}}
    end
  end

  # The held actor must be the session's own Member, so a Subject cannot be
  # re-pointed at another Member or borrow a session it does not hold.
  def fetch_session(%Subject{
        actor: %Accounts.Membership{id: membership_id},
        membership_id: membership_id,
        account: %Accounts.Account{id: account_id},
        session_token_id: token_id
      }) do
    if Enum.all?([account_id, membership_id, token_id], &Repo.valid_uuid?/1) do
      UserToken.Query.authorized()
      |> UserToken.Query.by_id(token_id)
      |> UserToken.Query.by_membership(account_id, membership_id)
      |> UserToken.Query.with_preloaded_authority()
      |> Repo.fetch(UserToken.Query)
      |> case do
        {:ok, session} -> {:ok, session}
        {:error, :not_found} -> {:error, :unauthorized}
      end
    else
      {:error, :unauthorized}
    end
  end

  def fetch_session(%Subject{}), do: {:error, :unauthorized}
end
