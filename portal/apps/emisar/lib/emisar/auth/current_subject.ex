defmodule Emisar.Auth.CurrentSubject do
  @moduledoc false

  alias Emisar.{Accounts, ApiKeys, Repo, Users}
  alias Emisar.Auth.{Permissions, Subject}

  # Auth.fetch_current_subject/2 checks the caller's snapshot permissions first.
  # These existing context lookups own the active-account and identity queries;
  # this module only binds their results to the authenticated subject.
  def fetch(
        %Subject{
          account: %Accounts.Account{id: account_id},
          actor: %Users.User{id: user_id} = user,
          membership_id: membership_id
        } = subject
      ) do
    with true <- valid_ids?([account_id, user_id, membership_id]),
         {:ok, %Accounts.Membership{id: ^membership_id} = membership} <-
           Accounts.fetch_membership_by_account_id_or_slug(user, account_id) do
      role = Subject.effective_membership_role(membership)
      {:ok, refreshed(subject, membership.account, membership.user, role)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def fetch(
        %Subject{
          account: %Accounts.Account{id: account_id},
          actor: %ApiKeys.ApiKey{id: key_id} = snapshot_key,
          membership_id: membership_id
        } = subject
      ) do
    with true <- valid_ids?([account_id, key_id, membership_id]),
         %ApiKeys.ApiKey{account_id: ^account_id, created_by_membership_id: ^membership_id} = key <-
           ApiKeys.peek_api_key_by_id(key_id),
         true <- key_binding(key) == key_binding(snapshot_key),
         true <- Repo.valid_uuid?(key.created_by_id),
         {:ok, %Accounts.Membership{id: ^membership_id} = membership} <-
           Accounts.fetch_membership_by_account_id_or_slug(
             %Users.User{id: key.created_by_id},
             account_id
           ) do
      {:ok, refreshed(subject, membership.account, key, :api_client)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def fetch(%Subject{}), do: {:error, :unauthorized}

  defp valid_ids?(ids), do: Enum.all?(ids, &Repo.valid_uuid?/1)

  # Mutable usage/name/expiry facts refresh normally; immutable credential
  # identity must never be rebound to another creator, kind, or recovery lineage.
  defp key_binding(key) do
    {key.account_id, key.created_by_id, key.created_by_membership_id, key.kind,
     key.credential_lineage_id}
  end

  defp refreshed(subject, account, actor, role) do
    permissions = MapSet.intersection(subject.permissions, Permissions.for_role(role))
    %{subject | account: account, actor: actor, role: role, permissions: permissions}
  end
end
