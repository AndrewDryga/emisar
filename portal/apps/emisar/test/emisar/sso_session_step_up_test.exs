defmodule Emisar.SSOSessionStepUpTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Audit, Auth, Config, Crypto, Fixtures, Repo, RequestContext, SSO}

  defmodule StubOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl true
    def begin_authorization(_provider, opts) do
      send(self(), {:oidc_begin, opts})

      {:ok,
       %{
         authorize_url: "https://idp.test/authorize",
         state: "state",
         nonce: "nonce",
         pkce_verifier: "verifier"
       }}
    end

    @impl true
    def verify_callback(_provider, params, _stash) do
      send(self(), :oidc_callback)

      case params do
        %{"error" => _} -> {:error, :access_denied}
        %{"claims" => claims} -> {:ok, %{identifier: claims["sub"], claims: claims}}
      end
    end
  end

  defmodule RecordingDisconnector do
    def disconnect_live_sessions(topics) do
      send(self(), {:disconnect, topics})
      :ok
    end
  end

  setup do
    Config.put_override(:emisar, :sso_oidc_impl, StubOIDC)
    Config.put_override(:emisar, :session_disconnect_handler, {:emisar, RecordingDisconnector})
    user = Fixtures.Users.create_user()
    account = Fixtures.Accounts.create_account(plan: "enterprise")

    member =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: :viewer
      )

    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

    identity =
      Fixtures.SSO.create_user_identity(
        account_id: account.id,
        provider_id: provider.id,
        user_id: user.id
      )

    %{user: user, account: account, member: member, provider: provider, identity: identity}
  end

  describe "list_session_step_up_providers/1" do
    test "lists only linked providers for the exact destination", %{
      user: user,
      account: account,
      provider: provider
    } do
      foreign = Fixtures.Accounts.create_account(plan: "enterprise")
      Fixtures.Memberships.create_membership(account_id: foreign.id, user_id: user.id)
      other_provider = Fixtures.SSO.create_identity_provider(account_id: foreign.id)

      Fixtures.SSO.create_user_identity(
        account_id: foreign.id,
        provider_id: other_provider.id,
        user_id: user.id
      )

      browser = browser(user, account)

      assert {:ok, [listed]} = SSO.list_session_step_up_providers(browser.subject)
      assert listed.id == provider.id
    end

    test "denies missing permission before exposing linked providers", %{
      user: user,
      account: account
    } do
      browser = browser(user, account)

      assert SSO.list_session_step_up_providers(%{browser.subject | permissions: MapSet.new()}) ==
               {:error, :unauthorized}
    end
  end

  describe "begin_session_step_up/4" do
    test "binds the ceremony to the exact browser, Member and linked identity",
         %{user: _, account: _, member: _, provider: _, identity: _} = context do
      browser = browser(context.user, context.account)
      stash = begin_step_up(context, browser)
      assert stash.purpose == :workspace_sso
      assert stash.actor_session_token_id == browser.session.id
      assert stash.actor_session_token_digest == browser.digest
      assert stash.member_grant_id == browser.subject.member_grant_id
      assert stash.account_id == context.account.id
      assert stash.provider_id == context.provider.id
      assert stash.identity_id == context.identity.id
      assert stash.provider_identifier == context.identity.provider_identifier

      assert stash.namespace ==
               {context.provider.issuer, context.provider.client_id,
                context.provider.identifier_claim}

      assert {:ok, _user, _session} = Auth.fetch_user_and_token_by_session_token(browser.raw)
    end

    test "denies missing permission and another workspace's provider before provider work",
         %{user: _, account: _, provider: _} = context do
      browser = browser(context.user, context.account)
      denied = %{browser.subject | permissions: MapSet.new()}

      assert SSO.begin_session_step_up(context.provider.id, callback(), browser.digest, denied) ==
               {:error, :unauthorized}

      foreign = Fixtures.SSO.create_identity_provider()

      assert SSO.begin_session_step_up(foreign.id, callback(), browser.digest, browser.subject) ==
               {:error, :identity_not_linked}

      refute_received {:oidc_begin, _}
    end
  end

  describe "complete_session_step_up/4" do
    test "a viewer proves required SSO without losing personal, local-factor or sibling proof",
         %{user: _, account: _, provider: _} = context do
      sibling = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: context.user.id)
      enrolling_subject = Fixtures.Subjects.subject_for(context.user, context.account)
      {user, _codes} = Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), enrolling_subject)
      browser = browser(user, context.account, DateTime.utc_now())
      other = browser(user, context.account, DateTime.utc_now())
      old_routes = routes(browser.session)
      Fixtures.Accounts.set_account_settings(context.account, %{require_sso: true})

      assert Accounts.ensure_account_compliant(context.account, browser.subject) ==
               {:error, :sso_required}

      stash = begin_step_up(context, browser)
      assert_received {:oidc_begin, options}
      refute Keyword.has_key?(options, :url_extension)

      assert Auth.fetch_user_and_token_by_session_token(browser.raw) ==
               {:ok, user, browser.session}

      :ok = Audit.subscribe_account_audit(context.account.id)

      assert {:ok, result} = complete(context, browser, stash)
      assert {:ok, _user, replacement} = Auth.fetch_user_and_token_by_session_token(result.token)
      assert Auth.fetch_user_and_token_by_session_token(browser.raw) == {:error, :not_found}
      assert {:ok, _user, _session} = Auth.fetch_user_and_token_by_session_token(other.raw)
      assert replacement.personal_proved_at == browser.session.personal_proved_at
      assert replacement.personal_expires_at == browser.session.personal_expires_at
      assert replacement.mfa_enrollment_verified_at == browser.session.mfa_enrollment_verified_at
      assert replacement.local_mfa_expires_at == browser.session.local_mfa_expires_at
      assert Enum.all?(old_routes, &(&1 in routes(replacement)))

      assert {:ok, _member} =
               Accounts.fetch_membership_by_account_id_or_slug(user, sibling.id, replacement)

      current = Fixtures.Subjects.subject_for(user, context.account, session: replacement)
      assert Accounts.ensure_account_compliant(context.account, current) == :ok
      assert Auth.ensure_personal_session(current) == :ok
      assert current.auth_method == :sso
      assert current.mfa
      topic = Auth.live_socket_topic_for_session(browser.raw)
      assert_received {:disconnect, [^topic]}
      assert_receive {:audit_event, %Audit.Event{event_type: "user.signed_in"}}

      assert complete(context, browser, stash) == {:error, :unauthorized}
      refute_received {:disconnect, _}
    end

    for field <- [
          :purpose,
          :actor_session_token_id,
          :actor_session_token_digest,
          :member_grant_id,
          :provider_id,
          :identity_id,
          :provider_identifier,
          :namespace,
          :started_at
        ] do
      @field field
      test "a mismatched #{@field} is rejected without replacing the browser",
           %{user: _, account: _} = context do
        browser = browser(context.user, context.account)
        stash = begin_step_up(context, browser) |> Map.put(@field, nil)
        assert {:error, _reason} = complete(context, browser, stash)
        assert {:ok, _user, _session} = Auth.fetch_user_and_token_by_session_token(browser.raw)
        refute_received {:disconnect, _}
      end
    end

    test "another browser for the same User cannot complete the ceremony",
         %{user: _, account: _} = context do
      original = browser(context.user, context.account)
      other = browser(context.user, context.account)
      stash = begin_step_up(context, original)
      assert complete(context, other, stash) == {:error, :session_step_up_invalid}

      assert SSO.complete_session_step_up(params(context), stash, other.digest, original.subject) ==
               {:error, :session_step_up_invalid}

      refute_received :oidc_callback
    end

    test "expiry, cancellation and a different identifier leave all donor proof intact",
         %{user: _, account: _} = context do
      browser = browser(context.user, context.account)
      stash = begin_step_up(context, browser)
      originals = routes(browser.session)

      assert complete(context, browser, %{stash | started_at: stash.started_at - 601}) ==
               {:error, :session_step_up_invalid}

      refute_received :oidc_callback

      assert SSO.complete_session_step_up(
               %{"error" => "access_denied"},
               stash,
               browser.digest,
               browser.subject
             ) == {:error, :access_denied}

      wrong_person = %{
        "claims" => %{
          "sub" => "another-person",
          "email" => context.user.email,
          "email_verified" => true
        }
      }

      assert SSO.complete_session_step_up(wrong_person, stash, browser.digest, browser.subject) ==
               {:error, :session_step_up_invalid}

      assert routes(browser.session) == originals
      assert {:ok, _user, _session} = Auth.fetch_user_and_token_by_session_token(browser.raw)
      assert Repo.aggregate(SSO.UserIdentity, :count) == 1
      assert Repo.aggregate(SSO.LinkRequest, :count) == 0
      refute_received {:disconnect, _}
    end

    test "a member invited back continues with SSO, which moves their identity to the new seat",
         %{user: _, account: _, member: _, provider: _, identity: _} = context do
      replacement = invite_back(context)
      browser = browser(context.user, context.account, nil, replacement)
      Fixtures.Accounts.set_account_settings(context.account, %{require_sso: true})

      assert {:ok, [listed]} = SSO.list_session_step_up_providers(browser.subject)
      assert listed.id == context.provider.id

      stash = begin_step_up(context, browser)
      :ok = Audit.subscribe_account_audit(context.account.id)

      assert {:ok, result} = complete(context, browser, stash)
      assert Repo.reload!(context.identity).membership_id == replacement.id
      assert_receive {:audit_event, %Audit.Event{event_type: "sso.identity_linked"}}

      assert {:ok, user, replacement_session} =
               Auth.fetch_user_and_token_by_session_token(result.token)

      current =
        Fixtures.Subjects.subject_for(user, context.account,
          session: replacement_session,
          membership: replacement
        )

      assert Accounts.ensure_account_compliant(context.account, current) == :ok
    end

    test "a failed proof leaves an identity on the removed seat",
         %{user: _, account: _, member: _, identity: _} = context do
      replacement = invite_back(context)
      browser = browser(context.user, context.account, nil, replacement)
      stash = begin_step_up(context, browser)
      wrong_person = %{"claims" => %{"sub" => "another-person"}}

      assert SSO.complete_session_step_up(wrong_person, stash, browser.digest, browser.subject) ==
               {:error, :session_step_up_invalid}

      assert Repo.reload!(context.identity).membership_id == context.member.id
      assert {:ok, _user, _session} = Auth.fetch_user_and_token_by_session_token(browser.raw)
    end

    test "a SCIM-synthesized identifier needs a token naming the same person, as at sign-in",
         %{user: _, account: _} = context do
      identity =
        context.identity
        |> Ecto.Changeset.change(
          provisioned_via: :scim,
          scim_external_id: context.identity.provider_identifier
        )
        |> Repo.update!()

      context = %{context | identity: identity}
      browser = browser(context.user, context.account)
      stash = begin_step_up(context, browser)
      originals = routes(browser.session)

      assert complete(context, browser, stash) == {:error, :session_step_up_invalid}
      assert routes(browser.session) == originals

      same_person = %{
        "claims" => %{
          "sub" => identity.provider_identifier,
          "email" => context.user.email,
          "email_verified" => true
        }
      }

      assert {:ok, _result} =
               SSO.complete_session_step_up(same_person, stash, browser.digest, browser.subject)
    end

    test "target grant revocation during the trip defeats otherwise valid SSO",
         %{user: _, account: _, member: _} = context do
      browser = browser(context.user, context.account)
      stash = begin_step_up(context, browser)
      owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), context.account)
      assert Accounts.end_all_sessions_for(context.member, owner) == :ok
      assert_received {:disconnect, _}
      assert complete(context, browser, stash) == {:error, :unauthorized}
      assert {:ok, _user, _session} = Auth.fetch_user_and_token_by_session_token(browser.raw)
      refute_received {:disconnect, _}
    end

    test "donor logout during the trip defeats the callback without minting a replacement",
         %{user: _, account: _} = context do
      browser = browser(context.user, context.account)
      stash = begin_step_up(context, browser)
      assert Auth.complete_session_sign_out(browser.raw) == :ok
      assert complete(context, browser, stash) == {:error, :unauthorized}
      assert Repo.aggregate(Auth.UserToken.Query.by_context("session"), :count) == 0
    end
  end

  describe "complete_sso_session_step_up/4" do
    test "retained personal proof completes a new-address verification after SSO rotation",
         %{user: user, account: account} = context do
      donor = browser(user, account)
      stash = begin_step_up(context, donor)
      assert {:ok, result} = complete(context, donor, stash)
      {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(result.token)
      current = Fixtures.Subjects.subject_for(user, account, session: session)
      digest = Crypto.hash(result.token)
      email = "rotated-#{Ecto.UUID.generate()}@example.test"
      assert current.auth_method == :sso
      assert {:ok, :code} = Auth.begin_email_change(email, current)
      assert_received {:email, current_mail}

      assert {:ok, proof} =
               Auth.confirm_email_change(
                 email,
                 Fixtures.Auth.code_from_email(current_mail),
                 digest,
                 current
               )

      assert_received {:email, new_mail}

      assert {:ok, changed} =
               Auth.complete_email_change(
                 proof.token_id,
                 proof.nonce,
                 Fixtures.Auth.code_from_email(new_mail),
                 digest,
                 current
               )

      assert changed.email == email
      assert Repo.reload!(session).personal_expires_at == donor.session.personal_expires_at
    end

    test "a retired sibling and a later same-issuer Member are not recreated by rotation",
         %{user: _, account: _, provider: _, member: _} = context do
      sibling = Fixtures.Accounts.create_account(plan: "enterprise")

      member =
        Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: context.user.id)

      sibling_provider =
        Fixtures.SSO.create_identity_provider(
          account_id: sibling.id,
          issuer: context.provider.issuer
        )

      Fixtures.SSO.create_user_identity(
        account_id: sibling.id,
        provider_id: sibling_provider.id,
        user_id: context.user.id
      )

      browser = browser(context.user, context.account)
      stash = begin_step_up(context, browser)
      owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), sibling)
      assert Accounts.end_all_sessions_for(member, owner) == :ok

      later = Fixtures.Accounts.create_account(plan: "enterprise")
      Fixtures.Memberships.create_membership(account_id: later.id, user_id: context.user.id)

      later_provider =
        Fixtures.SSO.create_identity_provider(
          account_id: later.id,
          issuer: context.provider.issuer
        )

      Fixtures.SSO.create_user_identity(
        account_id: later.id,
        provider_id: later_provider.id,
        user_id: context.user.id
      )

      assert {:ok, result} = complete(context, browser, stash)
      assert {:ok, _user, replacement} = Auth.fetch_user_and_token_by_session_token(result.token)

      assert Accounts.fetch_membership_by_account_id_or_slug(
               context.user,
               sibling.id,
               replacement
             ) ==
               {:error, :not_found}

      assert Accounts.fetch_membership_by_account_id_or_slug(context.user, later.id, replacement) ==
               {:error, :not_found}

      assert Auth.session_membership_ids(context.user.id, replacement) == [context.member.id]
    end

    test "dormant disabled-workspace proof transfers unchanged and can recover",
         %{user: _, account: _} = context do
      sibling = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: context.user.id)
      browser = browser(context.user, context.account)
      originals = routes(browser.session)
      Fixtures.Accounts.disable_account(sibling)
      stash = begin_step_up(context, browser)
      assert {:ok, result} = complete(context, browser, stash)
      assert {:ok, _user, replacement} = Auth.fetch_user_and_token_by_session_token(result.token)
      assert Enum.all?(originals, &(&1 in routes(replacement)))

      assert Accounts.fetch_membership_by_account_id_or_slug(
               context.user,
               sibling.id,
               replacement
             ) ==
               {:error, :not_found}

      assert {:ok, _} =
               Emisar.Admin.execute("emisar.admin.account.enable", [
                 "account=#{sibling.slug}",
                 "reason=restore test workspace"
               ])

      assert {:ok, _} =
               Accounts.fetch_membership_by_account_id_or_slug(
                 context.user,
                 sibling.id,
                 replacement
               )
    end

    test "audit failure rolls back replacement, transfer and donor consumption without disconnect",
         %{user: _, account: _} = context do
      browser = browser(context.user, context.account)
      stash = begin_step_up(context, browser)
      originals = routes(browser.session)

      bad = %{
        browser
        | subject: %{browser.subject | context: %RequestContext{request_id: %{invalid: true}}}
      }

      :ok = Audit.subscribe_account_audit(context.account.id)
      assert {:error, changeset} = complete(context, bad, stash)
      assert "is invalid" in errors_on(changeset).request_id
      assert {:ok, _user, _session} = Auth.fetch_user_and_token_by_session_token(browser.raw)
      assert routes(browser.session) == originals
      assert Repo.aggregate(Auth.UserToken.Query.by_context("session"), :count) == 1
      refute_received {:disconnect, _}
      refute_received {:audit_event, _}
      assert {:ok, _result} = complete(context, browser, stash)
    end

    test "another SSO proof cannot renew expired personal or local MFA evidence",
         %{user: _, account: _} = context do
      sibling = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: context.user.id)
      enrolling_subject = Fixtures.Subjects.subject_for(context.user, context.account)
      {user, _codes} = Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), enrolling_subject)
      browser = browser(user, context.account, DateTime.utc_now())
      assert {:ok, result} = complete(context, browser, begin_step_up(context, browser))
      Fixtures.Auth.expire_session_independent_proofs!(result.token)
      {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(result.token)
      subject = Fixtures.Subjects.subject_for(user, context.account, session: session)

      donor = %{
        raw: result.token,
        digest: Crypto.hash(result.token),
        session: session,
        subject: subject
      }

      assert {:ok, next} = complete(context, donor, begin_step_up(context, donor))
      {:ok, _user, replacement} = Auth.fetch_user_and_token_by_session_token(next.token)
      current = Fixtures.Subjects.subject_for(user, context.account, session: replacement)
      assert replacement.personal_expires_at == session.personal_expires_at
      assert replacement.local_mfa_expires_at == session.local_mfa_expires_at
      assert Auth.ensure_personal_session(current) == {:error, :unauthorized}
      refute current.mfa

      assert Accounts.fetch_membership_by_account_id_or_slug(user, sibling.id, replacement) ==
               {:error, :not_found}
    end

    test "an empty sibling parent cannot reacquire routes after its provider retires the proof",
         %{user: _, account: _, provider: _, identity: _} = context do
      sibling = Fixtures.Accounts.create_account(plan: "enterprise")
      Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: context.user.id)

      provider =
        Fixtures.SSO.create_identity_provider(
          account_id: sibling.id,
          issuer: context.provider.issuer,
          satisfies_mfa: true
        )

      Fixtures.SSO.create_user_identity(
        account_id: sibling.id,
        provider_id: provider.id,
        user_id: context.user.id
      )

      {:ok, raw, false} =
        Auth.complete_sso_account_sign_in(context.user, context.account.id, %RequestContext{},
          user_identity_id: context.identity.id,
          provider_identifier: context.identity.provider_identifier
        )

      {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(raw)
      subject = Fixtures.Subjects.subject_for(context.user, context.account, session: session)
      browser = %{raw: raw, digest: Crypto.hash(raw), session: session, subject: subject}
      stash = begin_step_up(context, browser)
      owner = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), sibling)
      assert {:ok, _provider} = SSO.update_provider(provider, %{satisfies_mfa: false}, owner)

      assert {:ok, result} = complete(context, browser, stash)
      {:ok, _user, replacement} = Auth.fetch_user_and_token_by_session_token(result.token)

      assert Accounts.fetch_membership_by_account_id_or_slug(
               context.user,
               sibling.id,
               replacement
             ) ==
               {:error, :not_found}

      assert Auth.ensure_personal_session(
               Fixtures.Subjects.subject_for(context.user, context.account, session: replacement)
             ) == {:error, :unauthorized}

      assert length(Repo.all(Auth.MemberGrant.Query.by_token_id(replacement.id))) == 2
      refute Enum.any?(routes(replacement), &(&1.account_id == sibling.id))
    end
  end

  describe "put_personal_session/2" do
    test "locks the current User and retained personal browser, not the Subject snapshot",
         %{user: user, account: account} = context do
      donor = browser(user, account)
      assert {:ok, result} = complete(context, donor, begin_step_up(context, donor))
      {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(result.token)
      subject = Fixtures.Subjects.subject_for(user, account, session: session)

      updated =
        user
        |> Emisar.Users.User.Changeset.profile(%{full_name: "Current Owner"})
        |> Repo.update!()

      assert {:ok, %{user: locked_user, personal_session: locked_session}} =
               Ecto.Multi.new() |> Auth.put_personal_session(subject) |> Repo.commit_multi()

      assert locked_user.full_name == updated.full_name
      assert locked_session.id == session.id
      assert locked_session.personal_proved_at == donor.session.personal_proved_at
      other = Fixtures.Users.create_user()

      assert Ecto.Multi.new()
             |> Auth.put_personal_session(%{subject | actor: other})
             |> Repo.commit_multi() == {:error, :unauthorized}
    end
  end

  describe "put_created_membership_grant/1" do
    test "a later failure restores retired identity proof and discards the new grant",
         %{identity: identity, user: user, account: account} = context do
      identity |> Ecto.Changeset.change(created_by: :admin) |> Repo.update!()
      donor = browser(user, account)
      assert {:ok, result} = complete(context, donor, begin_step_up(context, donor))
      assert_received {:disconnect, _}
      {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(result.token)
      subject = Fixtures.Subjects.subject_for(user, account, session: session)
      target = Fixtures.Accounts.create_account()
      before_routes = routes(session)

      assert {:error, :forced_rollback} =
               Ecto.Multi.new()
               |> Auth.put_personal_session(subject)
               |> Ecto.Multi.insert(
                 :membership,
                 Accounts.Membership.Changeset.create(%{
                   account_id: target.id,
                   user_id: user.id,
                   role: :owner
                 })
               )
               |> Ecto.Multi.merge(fn %{membership: member} ->
                 Accounts.put_membership_activation_consequence(Ecto.Multi.new(), member)
               end)
               |> Auth.put_created_membership_grant()
               |> Ecto.Multi.run(:forced_failure, fn _repo, changes ->
                 assert changes.retired_bindings.socket_topics == [
                          Auth.live_socket_topic(session.token)
                        ]

                 assert [grant] = changes.member_grants
                 assert grant.account_id == target.id
                 {:error, :forced_rollback}
               end)
               |> Repo.commit_multi(
                 after_commit: &Accounts.after_membership_activation_committed/1
               )

      assert routes(session) == before_routes
      assert Auth.session_grant_account_ids(session.id) == [context.account.id]
      refute Repo.reload!(context.identity).provider_identifier_retired_at
      refute Repo.reload!(context.identity).deleted_at

      refute Repo.exists?(
               Accounts.Membership.Query.all()
               |> Accounts.Membership.Query.by_account_id(target.id)
             )

      refute_received {:disconnect, _}
    end
  end

  # An owner removes the member and invites the same person back: their SSO
  # identity still names the removed seat.
  defp invite_back(%{account: account, member: member, user: user}) do
    owner =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: Fixtures.Users.create_user().id,
        role: :owner
      )

    assert {:ok, _removed} =
             Accounts.delete_membership(member, Fixtures.Subjects.membership_subject(owner))

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: user.id,
      role: :viewer
    )
  end

  defp browser(user, account, mfa_at \\ nil, membership \\ nil) do
    raw = Fixtures.Auth.create_session_token!(user, :magic_link, mfa_at)
    {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(raw)

    subject =
      Fixtures.Subjects.subject_for(user, account, session: session, membership: membership)

    %{raw: raw, digest: Crypto.hash(raw), session: session, subject: subject}
  end

  defp begin_step_up(context, browser) do
    assert {:ok, stash} =
             SSO.begin_session_step_up(
               context.provider.id,
               callback(),
               browser.digest,
               browser.subject
             )

    Map.put(stash, :redirect_uri, callback())
  end

  defp complete(context, browser, stash),
    do: SSO.complete_session_step_up(params(context), stash, browser.digest, browser.subject)

  defp params(context), do: %{"claims" => %{"sub" => context.identity.provider_identifier}}
  defp callback, do: "https://emisar.test/sign_in/sso/callback"

  defp routes(session) do
    Auth.MemberGrantRoute.Query.by_token_id(session.id)
    |> Auth.MemberGrantRoute.Query.ordered_by_proof()
    |> Repo.all()
  end
end
