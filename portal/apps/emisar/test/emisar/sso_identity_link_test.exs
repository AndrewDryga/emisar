defmodule Emisar.SSOIdentityLinkTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Audit, Auth, Crypto, Fixtures, Mail, Repo, SSO}
  alias Emisar.Auth.UserToken
  alias Emisar.SSO.{IdentityProvider, UserIdentity}

  defmodule StubOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(_provider, opts) do
      send(self(), {:identity_link_begin_options, opts})

      {:ok,
       %{
         authorize_url: "https://idp.test/authorize",
         state: "state",
         nonce: "nonce",
         pkce_verifier: "verifier"
       }}
    end

    @impl Emisar.SSO.OIDC
    def verify_callback(_provider, %{"_claims" => claims}, _stashed),
      do: {:ok, %{identifier: claims["sub"], claims: claims}}
  end

  setup do
    Emisar.Config.put_override(:emisar, :sso_oidc_impl, StubOIDC)
    {user, account, _subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id, name: "Workforce")
    raw_session = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
    {:ok, session} = Auth.fetch_session_by_token(raw_session)
    subject = Fixtures.Subjects.subject_for(user, account, session: session)

    %{
      account: account,
      provider: provider,
      raw_session: raw_session,
      session_digest: Crypto.hash(raw_session),
      subject: subject,
      user: user
    }
  end

  describe "begin_oidc_identity_step_up/4" do
    test "an emailed proof code is single-use and purpose-bound",
         %{subject: _subject} = context do
      assert {:ok, :email} =
               Auth.begin_oidc_identity_step_up(
                 context.provider.id,
                 context.provider.name,
                 :link,
                 context.subject
               )

      assert_received {:email, email}
      code = Fixtures.Auth.code_from_email(email)

      assert {:ok, proof} =
               Auth.confirm_oidc_identity_step_up(
                 context.provider.id,
                 :link,
                 code,
                 context.subject
               )

      assert Auth.confirm_oidc_identity_step_up(
               context.provider.id,
               :link,
               code,
               context.subject
             ) == {:error, :invalid}

      # The miss is audited (a hijacked session grinding the emailed code leaves a
      # trail) — the same accountability the TOTP factor path already had.
      assert [%Audit.Event{event_type: "user.oidc_identity_step_up_failed"}] =
               Audit.Event.Query.all()
               |> Audit.Event.Query.by_event_type("user.oidc_identity_step_up_failed")
               |> Repo.all()

      assert Auth.verify_oidc_identity_step_up_proof(
               proof,
               context.provider.id,
               :verify_provider,
               context.user
             ) == {:error, :identity_step_up_stale}
    end

    test "uses the existing authenticator instead of issuing an inbox code",
         %{subject: subject} = context do
      secret = Auth.generate_mfa_secret()
      {:ok, enrolled, _codes} = Fixtures.Users.enroll_mfa(secret, subject)

      assert Auth.begin_oidc_identity_step_up(
               context.provider.id,
               context.provider.name,
               :link,
               context.subject
             ) == {:ok, :mfa}

      refute_received {:email, _email}

      assert {:ok, proof} =
               Auth.confirm_oidc_identity_step_up(
                 context.provider.id,
                 :link,
                 Fixtures.Auth.totp_code(secret),
                 context.subject
               )

      assert :ok =
               Auth.verify_oidc_identity_step_up_proof(
                 proof,
                 context.provider.id,
                 :link,
                 Repo.reload!(enrolled)
               )
    end

    test "a suppressed current address can't begin the emailed-code step-up",
         %{user: user} = context do
      {:ok, _suppression} = Mail.suppress(user.email, :hard_bounce, "bounce")

      assert Auth.begin_oidc_identity_step_up(
               context.provider.id,
               context.provider.name,
               :link,
               context.subject
             ) == {:error, :delivery_suppressed}

      refute_received {:email, _}
    end
  end

  describe "resend_oidc_identity_step_up_code/4" do
    test "replaces the prior inbox code for the same provider and purpose",
         %{subject: _subject} = context do
      assert {:ok, :email} =
               Auth.begin_oidc_identity_step_up(
                 context.provider.id,
                 context.provider.name,
                 :link,
                 context.subject
               )

      assert_received {:email, first_email}

      assert {:ok, :sent} =
               Auth.resend_oidc_identity_step_up_code(
                 context.provider.id,
                 context.provider.name,
                 :link,
                 context.subject
               )

      assert_received {:email, second_email}

      assert Auth.confirm_oidc_identity_step_up(
               context.provider.id,
               :link,
               Fixtures.Auth.code_from_email(first_email),
               context.subject
             ) == {:error, :invalid}

      assert {:ok, _proof} =
               Auth.confirm_oidc_identity_step_up(
                 context.provider.id,
                 :link,
                 Fixtures.Auth.code_from_email(second_email),
                 context.subject
               )
    end

    test "a suppressed current address is reported, not passed off as sent",
         %{user: user} = context do
      {:ok, _suppression} = Mail.suppress(user.email, :hard_bounce, "bounce")

      assert {:ok, :suppressed} =
               Auth.resend_oidc_identity_step_up_code(
                 context.provider.id,
                 context.provider.name,
                 :link,
                 context.subject
               )

      refute_received {:email, _}
    end
  end

  describe "confirm_oidc_identity_step_up/4" do
    test "consumes an inbox code once", %{subject: _subject} = context do
      assert {:ok, :email} =
               Auth.begin_oidc_identity_step_up(
                 context.provider.id,
                 context.provider.name,
                 :link,
                 context.subject
               )

      assert_received {:email, email}
      code = Fixtures.Auth.code_from_email(email)

      assert {:ok, _proof} =
               Auth.confirm_oidc_identity_step_up(
                 context.provider.id,
                 :link,
                 code,
                 context.subject
               )

      assert Auth.confirm_oidc_identity_step_up(
               context.provider.id,
               :link,
               code,
               context.subject
             ) == {:error, :invalid}
    end
  end

  describe "verify_oidc_identity_step_up_proof/4" do
    test "rejects a proof under a different purpose", %{subject: _subject} = context do
      proof = local_proof(context, :link)

      assert Auth.verify_oidc_identity_step_up_proof(
               proof,
               context.provider.id,
               :verify_provider,
               context.user
             ) == {:error, :identity_step_up_stale}
    end
  end

  describe "ensure_oidc_identity_step_up_current/6" do
    test "requires the exact still-live browser session", %{subject: _subject} = context do
      proof = local_proof(context, :link)

      assert :ok =
               Auth.ensure_oidc_identity_step_up_current(
                 Repo,
                 proof,
                 context.session_digest,
                 context.provider.id,
                 :link,
                 context.user
               )

      assert :ok = Auth.delete_session_token(context.raw_session)

      assert Auth.ensure_oidc_identity_step_up_current(
               Repo,
               proof,
               context.session_digest,
               context.provider.id,
               :link,
               context.user
             ) == {:error, :identity_step_up_stale}
    end
  end

  describe "list_self_service_identity_facts/1" do
    test "lists enabled workspace methods without exposing provider configuration",
         %{provider: _provider, subject: _subject} = context do
      assert {:ok, [facts]} = SSO.list_self_service_identity_facts(context.subject)
      assert facts.provider_id == context.provider.id
      assert facts.provider_name == "Workforce"
      refute facts.linked?
      refute facts.user_verified?
      refute facts.removable?
      assert facts.removal_blocked_reason == :not_linked
      refute Map.has_key?(facts, :issuer)
      refute Map.has_key?(facts, :client_id)
    end

    test "workspace links need user verification; verified links can be removed",
         %{account: _account, provider: _provider, subject: _subject, user: _user} = context do
      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: context.account.id,
          provider_id: context.provider.id,
          user_id: context.user.id
        })

      assert {:ok, [facts]} = SSO.list_self_service_identity_facts(context.subject)
      assert facts.linked?
      refute facts.user_verified?
      refute facts.removable?
      assert facts.removal_blocked_reason == :identity_not_user_verified

      identity |> Ecto.Changeset.change(created_by: :user) |> Repo.update!()
      assert {:ok, [facts]} = SSO.list_self_service_identity_facts(context.subject)
      assert facts.user_verified?
      assert facts.removable?
      assert is_nil(facts.removal_blocked_reason)
    end

    test "only a usable alternative unblocks required-SSO removal",
         %{account: _account, provider: _provider, subject: _subject, user: _user} = context do
      identity = link_identity(context)
      context = with_sso_session(context, identity)
      Fixtures.Accounts.set_account_settings(context.account, %{require_sso: true})

      for state <- [:disabled, :deleted_provider, :retired, :deleted_identity] do
        provider =
          Fixtures.SSO.create_identity_provider(
            account_id: context.account.id,
            kind: :openid_connect
          )

        identity =
          Fixtures.SSO.create_user_identity(%{
            account_id: context.account.id,
            provider_id: provider.id,
            user_id: context.user.id
          })

        case state do
          :disabled ->
            Fixtures.SSO.disable_provider(provider)

          :deleted_provider ->
            Fixtures.SSO.mark_provider_deleted(provider)

          :retired ->
            identity
            |> Ecto.Changeset.change(provider_identifier_retired_at: DateTime.utc_now())
            |> Repo.update!()

          :deleted_identity ->
            identity |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()
        end

        assert {:ok, facts} = SSO.list_self_service_identity_facts(context.subject)
        refute Enum.find(facts, &(&1.provider_id == context.provider.id)).removable?
        Fixtures.SSO.disable_provider(provider)
      end

      assert {:ok, facts} = SSO.list_self_service_identity_facts(context.subject)
      current = Enum.find(facts, &(&1.provider_id == context.provider.id))
      assert current.user_verified?
      refute current.removable?
      assert current.removal_blocked_reason == :required_sso_identity

      alternative =
        Fixtures.SSO.create_identity_provider(
          account_id: context.account.id,
          kind: :openid_connect
        )

      Fixtures.SSO.create_user_identity(%{
        account_id: context.account.id,
        provider_id: alternative.id,
        user_id: context.user.id
      })

      assert {:ok, facts} = SSO.list_self_service_identity_facts(context.subject)
      assert Enum.find(facts, &(&1.provider_id == context.provider.id)).removable?
    end

    test "denied subjects cannot read methods and other users or accounts cannot supply alternatives",
         %{account: _account, provider: _provider, subject: _subject, user: _user} = context do
      denied = %{context.subject | permissions: MapSet.new()}
      assert SSO.list_self_service_identity_facts(denied) == {:error, :unauthorized}

      other_user = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: context.account.id,
        user_id: other_user.id
      )

      Fixtures.SSO.create_user_identity(%{
        account_id: context.account.id,
        provider_id: context.provider.id,
        user_id: other_user.id
      })

      assert {:ok, [facts]} = SSO.list_self_service_identity_facts(context.subject)
      refute facts.linked?
      assert is_nil(facts.identity_id)

      {_, foreign_account, _} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
      foreign_provider = Fixtures.SSO.create_identity_provider(account_id: foreign_account.id)

      Fixtures.Memberships.create_membership(
        account_id: foreign_account.id,
        user_id: context.user.id
      )

      Fixtures.SSO.create_user_identity(%{
        account_id: foreign_account.id,
        provider_id: foreign_provider.id,
        user_id: context.user.id
      })

      identity = link_identity(context)
      context = with_sso_session(context, identity)
      Fixtures.Accounts.set_account_settings(context.account, %{require_sso: true})
      assert {:ok, [facts]} = SSO.list_self_service_identity_facts(context.subject)
      assert facts.provider_id == context.provider.id
      assert facts.removal_blocked_reason == :required_sso_identity
    end
  end

  describe "provider_sign_in_verification_facts/2" do
    test "starts unverified and is scoped to the current account",
         %{subject: _subject} = context do
      assert {:ok, %{status: :unverified, linked?: false}} =
               SSO.provider_sign_in_verification_facts(context.provider, context.subject)

      {_other_user, _other_account, other_subject} =
        Fixtures.Subjects.owner_subject(%{plan: "enterprise"})

      assert SSO.provider_sign_in_verification_facts(context.provider, other_subject) ==
               {:error, :not_found}
    end

    test "a verifier's replacement seat inherits neither identity nor attribution, but the receipt remains valid",
         %{account: account, provider: provider, user: user} = context do
      _identity = link_identity(context)
      member = Fixtures.Memberships.fetch_membership(account.id, user.id)
      provider = Fixtures.SSO.verify_provider_sign_in(provider, member)

      provider =
        provider |> IdentityProvider.Changeset.update(%{enabled: false}) |> Repo.update!()

      Fixtures.Memberships.mark_membership_as_deleted(member)

      replacement =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.membership_subject(replacement)

      assert {:ok, %{status: :verified, linked?: false, verified_by_current_member?: false}} =
               SSO.provider_sign_in_verification_facts(provider, subject)

      Fixtures.Memberships.hard_delete_membership(member)
      assert is_nil(Repo.reload!(provider).sign_in_verified_by_membership_id)

      assert {:ok, %{status: :verified}} =
               SSO.provider_sign_in_verification_facts(provider, subject)

      assert {:ok, enabled} = SSO.update_provider(provider, %{enabled: true}, subject)
      assert enabled.enabled
    end
  end

  describe "begin_identity_link/6" do
    test "links only the current user and leaves the current session provenance unchanged",
         %{provider: _provider, subject: _subject, user: _user} = context do
      Fixtures.Memberships.fetch_membership(context.account.id, context.user.id)
      |> Ecto.Changeset.change(
        display_name: "Workspace Linker",
        contact_email: "local@example.test"
      )
      |> Repo.update!()

      proof = local_proof(context, :link)

      assert {:ok, begun} =
               SSO.begin_identity_link(
                 context.provider.id,
                 :link,
                 "https://emisar.test/sign_in/sso/callback",
                 proof,
                 context.session_digest,
                 context.subject
               )

      assert_receive {:identity_link_begin_options, options}
      assert options[:url_extension] == [{"prompt", "login"}, {"max_age", "0"}]

      assert {:ok, %{identity: identity, purpose: :link}} =
               SSO.complete_identity_link(
                 callback("workforce|user"),
                 begun,
                 context.session_digest,
                 context.subject
               )

      assert identity.membership_id == context.subject.membership_id
      assert identity.provider_id == context.provider.id
      assert identity.created_by == :user
      assert identity.provisioned_via == :oidc_link

      assert {:ok, [event], _} =
               Emisar.Audit.list_events(context.subject,
                 filter: [event_type: ["sso.identity_linked"]]
               )

      assert event.target_label == "Workspace Linker"

      assert {:ok, %UserToken{auth_method: :magic_link, user_identity_id: nil}} =
               Auth.fetch_session_by_token(context.raw_session)
    end

    test "refuses a provider that belongs to another account",
         %{provider: _provider, subject: _subject} = context do
      {_other_user, other_account, _other_subject} =
        Fixtures.Subjects.owner_subject(%{plan: "enterprise"})

      foreign =
        Fixtures.SSO.create_identity_provider(account_id: other_account.id, name: "Other")

      proof = local_proof(context, :link)

      assert {:error, :not_found} =
               SSO.begin_identity_link(
                 foreign.id,
                 :link,
                 "https://emisar.test/sign_in/sso/callback",
                 proof,
                 context.session_digest,
                 context.subject
               )
    end
  end

  describe "complete_identity_link/4" do
    test "fails closed when the provider subject belongs to another user",
         %{account: _account, provider: _provider, subject: _subject, user: _user} = context do
      other = Fixtures.Users.create_user()
      Fixtures.Memberships.create_membership(account_id: context.account.id, user_id: other.id)

      _identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: context.account.id,
          provider_id: context.provider.id,
          user_id: other.id,
          provider_identifier: "workforce|taken"
        })

      proof = local_proof(context, :link)

      {:ok, begun} =
        SSO.begin_identity_link(
          context.provider.id,
          :link,
          "https://emisar.test/sign_in/sso/callback",
          proof,
          context.session_digest,
          context.subject
        )

      assert SSO.complete_identity_link(
               callback("workforce|taken"),
               begun,
               context.session_digest,
               context.subject
             ) == {:error, :identity_already_linked}

      refute Repo.exists?(
               UserIdentity.Query.not_deleted()
               |> UserIdentity.Query.by_provider_id(context.provider.id)
               |> UserIdentity.Query.by_member_user_id(context.user.id)
             )
    end

    test "a member invited back links the identity left on their removed seat to the new one",
         %{account: _account, provider: _provider, user: _user} = context do
      seat = Fixtures.Memberships.fetch_membership(context.account.id, context.user.id)

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: context.account.id,
          provider_id: context.provider.id,
          membership: seat,
          provider_identifier: "workforce|returning"
        })

      Fixtures.Memberships.mark_membership_as_deleted(seat)

      replacement =
        Fixtures.Memberships.create_membership(
          account_id: context.account.id,
          user_id: context.user.id,
          role: "admin"
        )

      raw = Fixtures.Auth.create_session_token!(context.user, :magic_link, nil)
      {:ok, session} = Auth.fetch_session_by_token(raw)

      subject =
        Fixtures.Subjects.subject_for(context.user, context.account,
          session: session,
          membership: replacement
        )

      context = %{context | raw_session: raw, session_digest: Crypto.hash(raw), subject: subject}
      proof = local_proof(context, :link)

      {:ok, begun} =
        SSO.begin_identity_link(
          context.provider.id,
          :link,
          "https://emisar.test/sign_in/sso/callback",
          proof,
          context.session_digest,
          context.subject
        )

      assert {:ok, %{identity: linked}} =
               SSO.complete_identity_link(
                 callback("workforce|returning"),
                 begun,
                 context.session_digest,
                 context.subject
               )

      assert linked.id == identity.id
      assert linked.membership_id == replacement.id
    end

    test "provider verification works while disabled and becomes stale after config changes",
         %{provider: _provider, subject: _subject} = context do
      disabled =
        context.provider
        |> IdentityProvider.Changeset.update(%{enabled: false})
        |> Ecto.Changeset.change(sign_in_verified_by_user_id: context.user.id)
        |> Repo.update!()

      context = %{context | provider: disabled}
      proof = local_proof(context, :verify_provider)

      {:ok, begun} =
        SSO.begin_identity_link(
          disabled.id,
          :verify_provider,
          "https://emisar.test/sign_in/sso/callback",
          proof,
          context.session_digest,
          context.subject
        )

      assert {:ok, %{purpose: :verify_provider}} =
               SSO.complete_identity_link(
                 callback("workforce|admin"),
                 begun,
                 context.session_digest,
                 context.subject
               )

      assert {:ok, %{status: :verified, linked?: true}} =
               SSO.provider_sign_in_verification_facts(disabled, context.subject)

      verified = Repo.reload!(disabled)
      assert verified.sign_in_verified_by_membership_id == context.subject.membership_id
      assert is_nil(verified.sign_in_verified_by_user_id)

      assert {:ok, enabled} = SSO.update_provider(disabled, %{enabled: true}, context.subject)
      assert enabled.enabled

      enabled
      |> IdentityProvider.Changeset.update(%{client_secret: "rotated-secret"})
      |> Repo.update!()

      assert {:ok, %{status: :stale}} =
               SSO.provider_sign_in_verification_facts(enabled, context.subject)
    end

    test "rejects cross-account providers and a proof minted for another purpose",
         %{subject: _subject} = context do
      foreign = Fixtures.SSO.create_identity_provider()
      foreign_proof = local_proof(%{context | provider: foreign}, :link)

      assert SSO.begin_identity_link(
               foreign.id,
               :link,
               "https://emisar.test/sign_in/sso/callback",
               foreign_proof,
               context.session_digest,
               context.subject
             ) == {:error, :not_found}

      link_proof = local_proof(context, :link)

      assert SSO.begin_identity_link(
               context.provider.id,
               :verify_provider,
               "https://emisar.test/sign_in/sso/callback",
               link_proof,
               context.session_digest,
               context.subject
             ) == {:error, :identity_step_up_stale}
    end

    test "rejects a stale IdP auth_time and a session revoked during the round trip",
         %{subject: _subject} = context do
      proof = local_proof(context, :link)

      {:ok, begun} =
        SSO.begin_identity_link(
          context.provider.id,
          :link,
          "https://emisar.test/sign_in/sso/callback",
          proof,
          context.session_digest,
          context.subject
        )

      stale_callback =
        callback("workforce|user")
        |> put_in(["_claims", "auth_time"], begun.started_at - 300)

      assert SSO.complete_identity_link(
               stale_callback,
               begun,
               context.session_digest,
               context.subject
             ) == {:error, :identity_link_invalid}

      assert :ok = Auth.delete_session_token(context.raw_session)

      assert SSO.complete_identity_link(
               callback("workforce|user"),
               begun,
               context.session_digest,
               context.subject
             ) == {:error, :unauthorized}
    end

    test "rechecks administrator authority at the provider callback",
         %{account: account, subject: subject} = context do
      proof = local_proof(context, :verify_provider)

      {:ok, begun} =
        SSO.begin_identity_link(
          context.provider.id,
          :verify_provider,
          "https://emisar.test/sign_in/sso/callback",
          proof,
          context.session_digest,
          subject
        )

      membership = Fixtures.Memberships.fetch_membership(account.id, context.user.id)
      _membership = Fixtures.Memberships.force_role(membership, "viewer")

      assert SSO.complete_identity_link(
               callback("workforce|admin"),
               begun,
               context.session_digest,
               subject
             ) == {:error, :unauthorized}

      refute Repo.reload!(context.provider).sign_in_verified_at
    end
  end

  describe "unlink_identity/4" do
    test "a stale allowed presentation never bypasses the locked required-SSO check",
         %{account: _account, provider: _provider, subject: _subject, user: _user} = context do
      identity = link_identity(context)
      context = with_sso_session(context, identity)

      alternative =
        Fixtures.SSO.create_identity_provider(
          account_id: context.account.id,
          kind: :openid_connect
        )

      Fixtures.SSO.create_user_identity(%{
        account_id: context.account.id,
        provider_id: alternative.id,
        user_id: context.user.id
      })

      Fixtures.Accounts.set_account_settings(context.account, %{require_sso: true})
      assert {:ok, facts} = SSO.list_self_service_identity_facts(context.subject)
      assert Enum.find(facts, &(&1.provider_id == context.provider.id)).removable?

      Fixtures.SSO.disable_provider(alternative)
      proof = local_proof(context, :unlink)

      assert SSO.unlink_identity(identity.id, proof, context.session_digest, context.subject) ==
               {:error, :required_sso_identity}

      refute Repo.reload!(identity).deleted_at
    end

    test "removes the binding and its destination proof without deleting bearers",
         %{provider: _provider, subject: _subject, user: _user} = context do
      identity = link_identity(context)

      Fixtures.Memberships.fetch_membership(context.account.id, context.user.id)
      |> Ecto.Changeset.change(
        display_name: "Workspace Unlinker",
        contact_email: "local@example.test"
      )
      |> Repo.update!()

      provider_session =
        Fixtures.Auth.create_session_token!(context.user, :sso, nil, %{},
          user_identity_id: identity.id
        )

      unrelated_session = Fixtures.Auth.create_session_token!(context.user, :magic_link, nil)
      proof = local_proof(context, :unlink)

      assert {:ok, removed} =
               SSO.unlink_identity(
                 identity.id,
                 proof,
                 context.session_digest,
                 context.subject
               )

      assert removed.deleted_at

      assert {:ok, [event], _} =
               Emisar.Audit.list_events(context.subject,
                 filter: [event_type: ["sso.identity_unlinked"]]
               )

      assert event.target_label == "Workspace Unlinker"
      assert {:ok, session} = Auth.fetch_session_by_token(provider_session)

      assert Emisar.Accounts.fetch_membership_by_account_id_or_slug(
               context.account.id,
               session
             ) ==
               {:error, :not_found}

      assert {:ok, _token} = Auth.fetch_session_by_token(unrelated_session)

      assert {:ok, _token} =
               Auth.fetch_session_by_token(context.raw_session)
    end

    test "does not strand a membership when its account requires SSO",
         %{account: account, subject: _subject} = context do
      identity = link_identity(context)
      context = with_sso_session(context, identity)
      _account = Fixtures.Accounts.set_account_settings(account, %{require_sso: true})
      proof = local_proof(context, :unlink)

      assert SSO.unlink_identity(
               identity.id,
               proof,
               context.session_digest,
               context.subject
             ) == {:error, :required_sso_identity}

      refute Repo.reload!(identity).deleted_at
    end

    test "preserves a directory row while retiring its self-service sign-in identifier",
         %{account: account, provider: provider, subject: _subject, user: user} = context do
      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          user_id: user.id,
          created_by: :user,
          provisioned_via: :oidc_link,
          scim_external_id: "directory-42",
          scim_active: true
        })

      proof = local_proof(context, :unlink)

      assert {:ok, removed} =
               SSO.unlink_identity(
                 identity.id,
                 proof,
                 context.session_digest,
                 context.subject
               )

      refute removed.deleted_at
      assert removed.scim_external_id == "directory-42"
      assert removed.scim_active
      assert %DateTime{} = removed.provider_identifier_retired_at
    end
  end

  defp with_sso_session(context, identity) do
    raw =
      Fixtures.Auth.create_session_token!(context.user, :sso, nil, %{},
        user_identity_id: identity.id
      )

    {:ok, session} = Auth.fetch_session_by_token(raw)
    subject = Fixtures.Subjects.subject_for(context.user, context.account, session: session)
    %{context | raw_session: raw, session_digest: Crypto.hash(raw), subject: subject}
  end

  defp local_proof(context, purpose) do
    assert {:ok, :email} =
             Auth.begin_oidc_identity_step_up(
               context.provider.id,
               context.provider.name,
               purpose,
               context.subject
             )

    assert_received {:email, email}
    code = Fixtures.Auth.code_from_email(email)

    assert {:ok, proof} =
             Auth.confirm_oidc_identity_step_up(
               context.provider.id,
               purpose,
               code,
               context.subject
             )

    proof
  end

  defp link_identity(context) do
    proof = local_proof(context, :link)

    {:ok, begun} =
      SSO.begin_identity_link(
        context.provider.id,
        :link,
        "https://emisar.test/sign_in/sso/callback",
        proof,
        context.session_digest,
        context.subject
      )

    {:ok, %{identity: identity}} =
      SSO.complete_identity_link(
        callback("workforce|user"),
        begun,
        context.session_digest,
        context.subject
      )

    identity
  end

  defp callback(identifier) do
    %{
      "_claims" => %{
        "sub" => identifier,
        "email" => "person@example.com",
        "email_verified" => true,
        "auth_time" => System.system_time(:second)
      }
    }
  end
end
