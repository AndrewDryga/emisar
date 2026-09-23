defmodule Emisar.MembersWithoutPersonalLoginTest do
  @moduledoc """
  A workspace Member without a personal login signs in only through its
  workspace SSO identity. Its member-only session acts as that exact Member in
  that one workspace, and every personal-login surface refuses it.
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, ApiKeys, Approvals, Audit, Auth, Fixtures, OAuth, Runners, Runs, Users}
  alias Emisar.Auth.UserToken
  alias Emisar.RequestContext

  @redirect "https://claude.ai/api/mcp/auth_callback"

  defp sign_in_opts(identity),
    do: [user_identity_id: identity.id, provider_identifier: identity.provider_identifier]

  # A Member without a personal login, its workspace identity, and a signed-in
  # member-only session.
  defp signed_in_member(account, provider, role \\ "operator") do
    membership =
      Fixtures.Memberships.create_unlinked_membership(account_id: account.id, role: role)

    identity =
      Fixtures.SSO.create_user_identity(
        account_id: account.id,
        provider_id: provider.id,
        membership: membership
      )

    raw = Fixtures.Auth.create_member_session_token!(membership, identity)
    subject = Fixtures.Subjects.unlinked_member_subject(membership, raw)
    %{membership: membership, identity: identity, raw: raw, subject: subject}
  end

  test "SSO sign-in mints a member-only session for the Member's own seat, IdP MFA only" do
    account = Fixtures.Accounts.create_account(plan: "team")

    provider =
      Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: true)

    membership = Fixtures.Memberships.create_unlinked_membership(account_id: account.id)

    identity =
      Fixtures.SSO.create_user_identity(
        account_id: account.id,
        provider_id: provider.id,
        membership: membership
      )

    # Another workspace on the same issuer has its own unlinked Member: two
    # absent personal logins are never the same person.
    sibling = Fixtures.Accounts.create_account(plan: "team")

    sibling_provider =
      Fixtures.SSO.create_identity_provider(account_id: sibling.id, issuer: provider.issuer)

    stranger = Fixtures.Memberships.create_unlinked_membership(account_id: sibling.id)

    Fixtures.SSO.create_user_identity(
      account_id: sibling.id,
      provider_id: sibling_provider.id,
      membership: stranger
    )

    assert {:ok, raw, true} =
             Auth.complete_sso_account_sign_in(
               membership,
               account.id,
               %RequestContext{},
               sign_in_opts(identity)
             )

    assert {:ok, %UserToken{user_id: nil, user: nil} = session} =
             Auth.fetch_session_by_token(raw)

    assert session.auth_method == :sso
    assert session.user_identity_id == identity.id
    assert %DateTime{} = session.mfa_verified_at
    assert is_nil(session.personal_proved_at)
    assert is_nil(session.mfa_enrollment_verified_at)
    assert Auth.session_membership_ids(session) == [membership.id]

    member_id = membership.id

    assert %Audit.Event{actor_kind: "membership", actor_id: ^member_id} =
             Audit.Event.Query.all()
             |> Audit.Event.Query.by_event_type("user.signed_in")
             |> Repo.one()

    assert %DateTime{} = Repo.reload!(membership).last_active_at
  end

  test "SSO sign-in refuses a linked Member, another identity, another account and suspension" do
    account = Fixtures.Accounts.create_account(plan: "team")
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
    membership = Fixtures.Memberships.create_unlinked_membership(account_id: account.id)

    identity =
      Fixtures.SSO.create_user_identity(
        account_id: account.id,
        provider_id: provider.id,
        membership: membership
      )

    linked = Fixtures.Memberships.create_membership(account_id: account.id)
    other = Fixtures.Memberships.create_unlinked_membership(account_id: account.id)
    other_account = Fixtures.Accounts.create_account(plan: "team")
    context = %RequestContext{}
    opts = sign_in_opts(identity)

    assert Auth.complete_sso_account_sign_in(linked, account.id, context, opts) ==
             {:error, :provider_disabled}

    assert Auth.complete_sso_account_sign_in(other, account.id, context, opts) ==
             {:error, :provider_disabled}

    assert Auth.complete_sso_account_sign_in(membership, other_account.id, context, opts) ==
             {:error, :provider_disabled}

    Fixtures.Memberships.suspend_membership(membership)

    assert Auth.complete_sso_account_sign_in(membership, account.id, context, opts) ==
             {:error, :membership_unavailable}

    refute Repo.exists?(UserToken)
  end

  test "a Member without a personal login dispatches as its exact Member" do
    account = Fixtures.Accounts.create_account(plan: "team")
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
    %{membership: membership, subject: subject} = signed_in_member(account, provider)
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    Fixtures.Catalog.create_action(runner: runner)
    Fixtures.Policies.create_policy(account_id: account.id)
    attrs = Fixtures.Runs.dispatch_attrs(account_id: account.id, runner_id: runner.id)
    Runners.subscribe_runner_transport(runner)

    assert {:ok, :running, run} = Runs.dispatch_run(attrs, subject)
    assert run.initiating_membership_id == membership.id
    assert is_nil(run.requested_by_id)
    assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
  end

  test "a Member without a personal login decides as its exact Member" do
    account = Fixtures.Accounts.create_account(plan: "team")
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
    %{membership: approver, subject: subject} = signed_in_member(account, provider, "admin")
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    Fixtures.Catalog.create_action(runner: runner)
    Runners.subscribe_runner_transport(runner)
    requester = Fixtures.Memberships.create_membership(account_id: account.id)

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "linux.uptime",
        source: "operator",
        requested_by_id: requester.user_id,
        initiating_membership_id: requester.id,
        args: %{},
        pack_ref: Fixtures.Catalog.default_pack_ref(),
        expected_pack_hash: Fixtures.Catalog.default_pack_hash(),
        status: :pending_approval
      })

    {:ok, request} = Approvals.create_request(run, "needs review", min_approvals: 1)

    assert {:ok, {decided, %Runs.ActionRun{status: :sent}}} =
             Approvals.approve_request(request, subject, "Reviewed")

    assert decided.decided_by_membership_id == approver.id
    assert is_nil(decided.decided_by_id)
    assert_receive {:cloud_to_runner, _generation, %{"type" => "run_action"}}, 500
  end

  test "a Member without a personal login mints an MCP key that authenticates" do
    account = Fixtures.Accounts.create_account(plan: "team")
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
    %{membership: membership, subject: subject} = signed_in_member(account, provider)

    assert {:ok, raw, key} = ApiKeys.mint_quick_key(subject)
    assert key.created_by_membership_id == membership.id
    assert is_nil(key.created_by_id)

    key_id = key.id
    assert %ApiKeys.ApiKey{id: ^key_id} = ApiKeys.peek_api_key_by_secret(raw)
  end

  test "a Member without a personal login consents to an OAuth client" do
    account = Fixtures.Accounts.create_account(plan: "team")
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
    %{membership: membership, subject: subject} = signed_in_member(account, provider)

    {:ok, client} =
      OAuth.register_client(%{"client_name" => "Claude", "redirect_uris" => [@redirect]})

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    params = %{
      "redirect_uri" => @redirect,
      "response_type" => "code",
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "scope" => "mcp offline_access",
      "resource" => Emisar.PublicUrl.url("/api/mcp/rpc")
    }

    assert {:ok, _code, @redirect} = OAuth.issue_code(client, params, subject)

    member_id = membership.id

    assert %ApiKeys.ApiKey{created_by_membership_id: ^member_id, created_by_id: nil} =
             Repo.one(ApiKeys.ApiKey)
  end

  test "personal surfaces refuse a Member without a personal login; its workspace profile edits" do
    account = Fixtures.Accounts.create_account(plan: "team")
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

    %{membership: membership, raw: raw, subject: subject} =
      signed_in_member(account, provider)

    {:ok, session} = Auth.fetch_session_by_token(raw)
    account_count = Repo.aggregate(Accounts.Account, :count)

    assert Users.update_user_profile(%{"full_name" => "Renamed"}, subject) ==
             {:error, :personal_login_required}

    assert Auth.list_sessions_for_user(session.token, subject) ==
             {:error, :personal_login_required}

    assert Auth.begin_email_change("new@example.test", subject) ==
             {:error, :personal_login_required}

    assert Auth.mfa_facts(subject) == {:error, :personal_login_required}
    assert Auth.issue_mfa_enrollment_code(subject) == {:error, :personal_login_required}

    assert Accounts.create_account_with_owner_from_name("Second workspace", subject) ==
             {:error, :personal_login_required}

    assert Repo.aggregate(Accounts.Account, :count) == account_count
    refute_received {:email, _}

    assert {:ok, updated} =
             Accounts.update_own_member_profile(%{"display_name" => "Workspace Name"}, subject)

    assert updated.id == membership.id
    assert updated.display_name == "Workspace Name"

    member_id = membership.id

    assert %Audit.Event{actor_kind: "membership", actor_id: ^member_id} =
             Audit.Event.Query.all()
             |> Audit.Event.Query.by_event_type("membership.profile_updated")
             |> Repo.one()
  end

  test "a member-only session reaches no other workspace and cannot switch" do
    account = Fixtures.Accounts.create_account(plan: "team")
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

    %{membership: membership, raw: raw, subject: subject} =
      signed_in_member(account, provider)

    other = Fixtures.Accounts.create_account(plan: "team")

    other_provider =
      Fixtures.SSO.create_identity_provider(account_id: other.id, issuer: provider.issuer)

    signed_in_member(other, other_provider)
    {:ok, session} = Auth.fetch_session_by_token(raw)
    account_id = account.id
    membership_id = membership.id

    assert {:ok, [%Accounts.Account{id: ^account_id}], _metadata} =
             Accounts.list_accounts_for_user(subject)

    assert Accounts.fetch_membership_by_account_id_or_slug(other.id, session) ==
             {:error, :not_found}

    assert Accounts.switch_account(other.id, subject) == {:error, :not_found}

    assert {:ok, %Accounts.Membership{id: ^membership_id}} =
             Accounts.switch_account(account.id, subject)
  end

  for revocation <- [:suspended, :identity_retired, :provider_disabled] do
    test "a #{revocation} Member's session resolves nothing and holds no authority" do
      account = Fixtures.Accounts.create_account(plan: "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      %{membership: membership, identity: identity, raw: raw, subject: subject} =
        signed_in_member(account, provider)

      {:ok, session} = Auth.fetch_session_by_token(raw)
      permission = Runners.Authorizer.view_runners_permission()
      assert {:ok, _member} = Accounts.fetch_membership_by_account_id_or_slug(account.id, session)
      assert Auth.Authorizer.ensure_has_permissions(subject, permission) == :ok

      case unquote(revocation) do
        :suspended -> Fixtures.Memberships.suspend_membership(membership)
        :identity_retired -> Fixtures.SSO.retire_identity(identity)
        :provider_disabled -> Fixtures.SSO.disable_provider(provider)
      end

      assert Accounts.fetch_membership_by_account_id_or_slug(account.id, session) ==
               {:error, :not_found}

      assert Auth.Authorizer.ensure_has_permissions(subject, permission) ==
               {:error, :unauthorized}
    end
  end

  test "a reinstated Member without a personal login signs in again; its old session stays dead" do
    {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

    %{membership: membership, identity: identity, raw: raw} =
      signed_in_member(account, provider)

    {:ok, session} = Auth.fetch_session_by_token(raw)

    assert {:ok, _suspended} = Accounts.suspend_membership(membership, owner_subject)
    assert {:ok, reinstated} = Accounts.reinstate_membership(membership, owner_subject)
    assert is_nil(reinstated.disabled_at)

    assert Accounts.fetch_membership_by_account_id_or_slug(account.id, session) ==
             {:error, :not_found}

    assert {:ok, _raw, false} =
             Auth.complete_sso_account_sign_in(
               reinstated,
               account.id,
               %RequestContext{},
               sign_in_opts(identity)
             )
  end

  test "a Member without a personal login enforces MFA only while its IdP proves one" do
    account = Fixtures.Accounts.create_account(plan: "team")

    mfa_provider =
      Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: true)

    plain_provider =
      Fixtures.SSO.create_identity_provider(account_id: account.id, kind: :keycloak)

    %{subject: proved} = signed_in_member(account, mfa_provider, "owner")
    %{subject: unproved} = signed_in_member(account, plain_provider, "owner")
    require_mfa = %{"settings" => %{"require_mfa" => true}}

    assert {:ok, %{mfa_enforcement: :actor_not_enrolled}} =
             Accounts.fetch_team_security_facts(unproved)

    assert Accounts.update_account(account, require_mfa, unproved) ==
             {:error, :mfa_enrollment_required}

    assert {:ok, %{mfa_enforcement: :available}} = Accounts.fetch_team_security_facts(proved)
    assert {:ok, updated} = Accounts.update_account(account, require_mfa, proved)
    assert updated.settings.require_mfa
  end
end
