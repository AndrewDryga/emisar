defmodule Emisar.Seeds.DemoAccount do
  @moduledoc """
  Northstar Labs: the demo account, its owner, the default policy, and the two
  teammates every later section attributes work to. A reseed also retires the
  first-pass demo artifacts so an existing dev database upgrades in place.
  """

  alias Ecto.Multi
  alias Emisar.Accounts
  alias Emisar.Accounts.Account
  alias Emisar.Accounts.Membership
  alias Emisar.Audit
  alias Emisar.Policies
  alias Emisar.Repo
  alias Emisar.Runbooks
  alias Emisar.Runners
  alias Emisar.Seeds.Helpers

  @account_name "Northstar Labs"
  @email "demo@emisar.dev"
  @full_name "Maya Chen"

  @doc """
  Seeds the account and returns the context the rest of the seed builds on.
  Every person in it is a Member of the account: `owner`, `jordan` and
  `priya`, beside `account`, `owner_subject` and `policy`.
  """
  def run do
    {account, owner} = Helpers.ensure_account(@account_name, "demo", @email, @full_name)
    account = Helpers.reset_screenshot_sign_in_policy(account)

    owner_subject = Helpers.subject_for(account, owner)
    account = Helpers.ensure_account_name(account, @account_name, owner_subject)
    owner_subject = %{owner_subject | account: account}

    # The demo account is enterprise so SSO/SCIM is testable here.
    Helpers.seed_subscription(account, "enterprise")

    ctx = %{
      owner: owner,
      account: account,
      owner_subject: owner_subject
    }

    retire_first_pass_artifacts(ctx)

    Helpers.say("✓ #{@account_name} ready (slug=demo; sign in by email as #{@email})")

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
      case Accounts.peek_sync_membership_by_email(account.id, email) do
        nil -> :ok
        membership -> membership |> Membership.Changeset.delete() |> Repo.update!()
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

    :ok
  end

  defp seed_default_policy(%{account: account, owner_subject: owner_subject}) do
    if Policies.peek_policy_for_account(account.id) == nil do
      {:ok, _} = Policies.seed_policy(account.id, owner_subject.membership_id)
      Helpers.say("✓ Seeded default policy")
    end

    Policies.peek_policy_for_account(account.id)
  end

  @doc """
  Invites `email` as a standing, accepted Member of the demo account and
  returns that Member — or converges the one a previous seed (or a sign-in)
  left behind. The invitation is accepted the way the emailed code accepts it:
  with the teammate's name, verifying the invited address, and the acceptance
  receipt.
  """
  def invite_member(%{account: account, owner_subject: owner_subject}, email, full_name, role) do
    case Accounts.peek_sync_membership_by_email(account.id, email) do
      nil ->
        {:ok, %{membership: invitation}} =
          Accounts.invite_user_to_account(
            %{"email" => email, "role" => role, "runner_access_mode" => "all"},
            owner_subject
          )

        accept_invitation(invitation, full_name)

      %Membership{invitation_accepted_at: nil, invitation_token_digest: digest} = invitation
      when is_binary(digest) ->
        accept_invitation(invitation, full_name)

      %Membership{} = membership ->
        membership
        |> ensure_reinstated(owner_subject)
        |> Membership.Changeset.profile(%{display_name: full_name})
        |> Helpers.verify_seeded_address()
        |> Repo.update!()
        |> Helpers.clear_seeded_mfa()
    end
  end

  defp ensure_reinstated(%Membership{} = membership, owner_subject) do
    if Accounts.membership_disabled?(membership) do
      {:ok, reinstated} = Accounts.reinstate_membership(membership, owner_subject)
      reinstated
    else
      membership
    end
  end

  defp accept_invitation(%Membership{} = invitation, full_name) do
    {:ok, %{accepted: accepted}} =
      Multi.new()
      |> Multi.update(
        :accepted,
        Membership.Changeset.accept_invitation_with_profile(invitation, %{display_name: full_name})
      )
      |> Multi.insert(:audit, &Audit.Events.user_invitation_accepted(&1.accepted))
      |> Repo.commit_multi()

    accepted
  end
end
