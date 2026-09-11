defmodule Emisar.Seeds.DemoAccount do
  @moduledoc """
  Northstar Labs: the demo account, its owner, the default policy, and the two
  teammates every later section attributes work to. A reseed also retires the
  first-pass demo artifacts so an existing dev database upgrades in place.
  """

  alias Emisar.Accounts
  alias Emisar.Accounts.Account
  alias Emisar.Auth.Subject
  alias Emisar.Policies
  alias Emisar.Repo
  alias Emisar.Runbooks
  alias Emisar.Runners
  alias Emisar.Seeds.Helpers
  alias Emisar.Users
  alias Emisar.Users.User

  @account_name "Northstar Labs"
  @email "demo@emisar.dev"
  @full_name "Maya Chen"

  @doc """
  Seeds the account and returns the context the rest of the seed builds on:
  `user`, `account`, `owner_membership`, `owner_subject`, `policy`, `jordan`,
  and `priya`.
  """
  def run do
    user = Helpers.ensure_persona(@email, @full_name)
    account = Helpers.ensure_account(@account_name, "demo", user)
    {:ok, owner_membership} = Accounts.fetch_membership_for_session(user, account.id)
    owner_subject = Subject.for_user(user, account, owner_membership)
    account = Helpers.ensure_account_name(account, @account_name, owner_subject)
    owner_subject = Subject.for_user(user, account, owner_membership)

    # The demo account is enterprise so SSO/SCIM is testable here.
    Helpers.seed_subscription(account, "enterprise")

    ctx = %{
      user: user,
      account: account,
      owner_membership: owner_membership,
      owner_subject: owner_subject
    }

    retire_first_pass_artifacts(ctx)

    Helpers.say(
      "✓ #{@account_name} ready (slug=demo, owner=#{@email}, password=#{Helpers.password()})"
    )

    policy = seed_default_policy(ctx)

    jordan = invite_member(ctx, "jordan@emisar.dev", "Jordan Lee", "admin")
    priya = invite_member(ctx, "priya@emisar.dev", "Priya Shah", "operator")
    Helpers.say("✓ Teammates: Jordan (admin), Priya (operator)")

    Map.merge(ctx, %{policy: policy, jordan: jordan, priya: priya})
  end

  # Retire the first-pass demo artifacts so re-running seeds upgrades an existing
  # dev DB instead of preserving screenshot-hostile laptop/CI/cache-purge rows.
  # Only personas this seed no longer creates belong here. `sam@emisar.dev` was a
  # first-pass artifact that later came back as a member-access persona, so
  # retiring it deleted the membership the same run re-invites in the fleet
  # section — widening Sam's access to `all` and then narrowing it again, which
  # fires the session-refresh broadcast against an endpoint `mix run --no-start`
  # never started. Every re-seed of a database where Sam had signed in died there.
  defp retire_first_pass_artifacts(%{account: account, owner_subject: owner_subject}) do
    for email <- ["alex@emisar.dev"] do
      case Users.fetch_user_by_email(email) do
        {:ok, old_user} ->
          old_user = Helpers.clear_seeded_mfa(old_user)

          case Accounts.peek_sync_membership(account.id, old_user.id) do
            nil ->
              :ok

            membership ->
              membership
              |> Accounts.Membership.Changeset.delete()
              |> Repo.update!()
          end

        {:error, :not_found} ->
          :ok
      end
    end

    for name <- ["andrew-mbp", "ci-bot-runner", "edge-pop-fra"] do
      Runners.Runner.Query.not_deleted()
      |> Runners.Runner.Query.by_account_id(account.id)
      |> Runners.Runner.Query.by_name(name)
      |> Repo.delete_all()
    end

    account
    |> Helpers.account_api_keys()
    |> Enum.filter(&(&1.name in ["Claude — Andrew's terminal", "SIEM export — initial"]))
    |> Enum.each(fn key ->
      key
      |> Ecto.Changeset.change(deleted_at: Helpers.now())
      |> Repo.update!()
    end)

    case Helpers.peek_account_runbook(account, "nightly-edge-health") do
      nil -> :ok
      runbook -> {:ok, _runbook} = Runbooks.delete_runbook(runbook, owner_subject)
    end

    case Repo.fetch(
           Account.Query.not_deleted() |> Account.Query.by_slug("initech"),
           Account.Query
         ) do
      {:ok, old_account} ->
        old_account
        |> Ecto.Changeset.change(deleted_at: Helpers.now())
        |> Repo.update!()

      {:error, :not_found} ->
        :ok
    end

    case Users.fetch_user_by_email("owner@initech.test") do
      {:ok, old_user} -> Helpers.clear_seeded_mfa(old_user)
      {:error, :not_found} -> :ok
    end

    :ok
  end

  defp seed_default_policy(%{account: account, user: user}) do
    if Policies.peek_policy_for_account(account.id) == nil do
      {:ok, _} = Policies.seed_policy(account.id, user.id)
      Helpers.say("✓ Seeded default policy")
    end

    Policies.peek_policy_for_account(account.id)
  end

  @doc """
  Invites `email` as a standing, accepted member of the demo account — or
  converges the membership a previous seed (or a sign-in) left behind.
  """
  def invite_member(%{account: account, owner_subject: owner_subject}, email, full_name, role) do
    member =
      case Users.fetch_user_by_email(email) do
        {:ok, %User{} = existing_user} ->
          case Accounts.peek_sync_membership(account.id, existing_user.id) do
            nil ->
              {:ok, %{user: invited, membership: membership, invitation_token: token}} =
                Accounts.invite_user_to_account(
                  %{"email" => email, "role" => role, "runner_access_mode" => "all"},
                  owner_subject
                )

              {:ok, _membership} =
                Accounts.mark_invitation_accepted(membership, token, invited)

              invited

            membership ->
              membership =
                if Accounts.membership_disabled?(membership) do
                  {:ok, reinstated} = Accounts.reinstate_membership(membership, owner_subject)
                  reinstated
                else
                  membership
                end

              if is_nil(membership.invitation_accepted_at) do
                {:ok, %{membership: membership, invitation_token: token}} =
                  Accounts.resend_account_invitation(membership, owner_subject)

                {:ok, _membership} =
                  Accounts.mark_invitation_accepted(membership, token, existing_user)
              end

              existing_user
          end

        {:error, :not_found} ->
          {:ok, %{user: invited, membership: membership, invitation_token: token}} =
            Accounts.invite_user_to_account(
              %{"email" => email, "role" => role, "runner_access_mode" => "all"},
              owner_subject
            )

          {:ok, _membership} = Accounts.mark_invitation_accepted(membership, token, invited)
          invited
      end

    member
    |> Helpers.ensure_profile(full_name)
    |> Helpers.confirm_user()
    |> Helpers.clear_seeded_mfa()
  end
end
