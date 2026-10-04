defmodule Emisar.SSOIdentityLinkTest do
  @moduledoc """
  Verifying an SSO connection by signing in through it: the administrator's
  fresh local proof (an emailed code or its authenticator), the provider-bound
  ceremony, and the identity it binds to the acting Member.
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Audit, Auth, Crypto, Fixtures, Mail, Repo, RequestContext, SSO}
  alias Emisar.Auth.UserToken
  alias Emisar.SSO.{IdentityProvider, UserIdentity}

  @redirect_uri "https://emisar.test/sign_in/sso/callback"

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
    {owner, account, _subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id, name: "Workforce")
    raw_session = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)
    subject = Fixtures.Subjects.subject_for(owner, session: raw_session)

    %{
      account: account,
      provider: provider,
      raw_session: raw_session,
      session_digest: Crypto.hash(raw_session),
      subject: subject,
      member: owner
    }
  end

  describe "begin_oidc_identity_step_up/3" do
    test "an emailed proof code is single-use and provider-bound", %{
      account: account,
      member: member,
      provider: provider,
      subject: subject
    } do
      assert {:ok, :email} =
               Auth.begin_oidc_identity_step_up(
                 provider.id,
                 provider.name,
                 subject
               )

      assert_received {:email, email}
      assert email.to == [{"", member.email}]
      code = Fixtures.Auth.code_from_email(email)

      assert {:ok, proof} =
               Auth.confirm_oidc_identity_step_up(provider.id, code, subject)

      assert Auth.confirm_oidc_identity_step_up(provider.id, code, subject) ==
               {:error, :invalid}

      # The miss is audited (a hijacked session grinding the emailed code leaves a
      # trail) — the same accountability the TOTP factor path already had.
      assert [%Audit.Event{event_type: "user.oidc_identity_step_up_failed"} = miss] =
               Audit.Event.Query.all()
               |> Audit.Event.Query.by_event_type("user.oidc_identity_step_up_failed")
               |> Repo.all()

      assert miss.account_id == account.id
      assert miss.actor_id == member.id

      other =
        Fixtures.SSO.create_identity_provider(
          account_id: account.id,
          kind: :openid_connect
        )

      assert Auth.verify_oidc_identity_step_up_proof(proof, other.id, member) ==
               {:error, :identity_step_up_stale}

      assert Auth.verify_oidc_identity_step_up_proof(proof, provider.id, member) ==
               :ok
    end

    test "uses the existing authenticator instead of issuing an inbox code", %{
      provider: provider,
      subject: subject
    } do
      secret = Auth.generate_mfa_secret()
      {enrolled, _codes} = Fixtures.Memberships.enable_mfa!(secret, subject)

      assert Auth.begin_oidc_identity_step_up(
               provider.id,
               provider.name,
               subject
             ) == {:ok, :mfa}

      refute_received {:email, _email}

      assert {:ok, proof} =
               Auth.confirm_oidc_identity_step_up(
                 provider.id,
                 Fixtures.Auth.totp_code(secret),
                 subject
               )

      assert :ok =
               Auth.verify_oidc_identity_step_up_proof(
                 proof,
                 provider.id,
                 Repo.reload!(enrolled)
               )
    end

    test "a suppressed current address can't begin the emailed-code step-up", %{
      member: member,
      provider: provider,
      subject: subject
    } do
      {:ok, _suppression} = Mail.suppress(member.email, :hard_bounce, "bounce")

      assert Auth.begin_oidc_identity_step_up(
               provider.id,
               provider.name,
               subject
             ) == {:error, :delivery_suppressed}

      refute_received {:email, _}
    end

    test "a Member without a verified address or an authenticator has no proof to give", %{
      account: account,
      provider: provider
    } do
      directory =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "admin",
          email_verified?: false
        )

      subject = Fixtures.Subjects.subject_for(directory)

      assert Auth.begin_oidc_identity_step_up(
               provider.id,
               provider.name,
               subject
             ) == {:error, :email_unavailable}

      refute_received {:email, _}
    end

    test "the sixth emailed code in fifteen minutes is refused with one audited rate limit", %{
      account: account,
      member: member,
      provider: provider,
      subject: subject
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      for _ <- 1..5 do
        assert {:ok, :email} =
                 Auth.begin_oidc_identity_step_up(
                   provider.id,
                   provider.name,
                   subject
                 )

        assert_received {:email, _}
      end

      for _ <- 1..2 do
        assert Auth.begin_oidc_identity_step_up(
                 provider.id,
                 provider.name,
                 subject
               ) == {:error, :rate_limited}

        refute_received {:email, _}
      end

      assert [event] =
               Audit.Event.Query.all()
               |> Audit.Event.Query.by_account_id(account.id)
               |> Audit.Event.Query.by_event_type("user.oidc_identity_step_up_rate_limited")
               |> Repo.all()

      assert event.actor_id == member.id
      assert event.payload["scope"] == "oidc_identity_step_up_issue"
      assert event.payload["attempt_limit"] == 5
      assert event.payload["window_seconds"] == 900
    end
  end

  describe "resend_oidc_identity_step_up_code/3" do
    test "replaces the prior inbox code for the same provider", %{
      provider: provider,
      subject: subject
    } do
      assert {:ok, :email} =
               Auth.begin_oidc_identity_step_up(
                 provider.id,
                 provider.name,
                 subject
               )

      assert_received {:email, first_email}

      assert {:ok, :sent} =
               Auth.resend_oidc_identity_step_up_code(
                 provider.id,
                 provider.name,
                 subject
               )

      assert_received {:email, second_email}

      assert Auth.confirm_oidc_identity_step_up(
               provider.id,
               Fixtures.Auth.code_from_email(first_email),
               subject
             ) == {:error, :invalid}

      assert {:ok, _proof} =
               Auth.confirm_oidc_identity_step_up(
                 provider.id,
                 Fixtures.Auth.code_from_email(second_email),
                 subject
               )
    end

    test "a suppressed current address is reported, not passed off as sent", %{
      member: member,
      provider: provider,
      subject: subject
    } do
      {:ok, _suppression} = Mail.suppress(member.email, :hard_bounce, "bounce")

      assert {:ok, :suppressed} =
               Auth.resend_oidc_identity_step_up_code(
                 provider.id,
                 provider.name,
                 subject
               )

      refute_received {:email, _}
    end

    test "once an authenticator is enrolled the emailed code is no longer offered", %{
      provider: provider,
      subject: subject
    } do
      {:ok, _enrolled, _codes} =
        Fixtures.Memberships.enroll_mfa(Auth.generate_mfa_secret(), subject)

      assert Auth.resend_oidc_identity_step_up_code(
               provider.id,
               provider.name,
               subject
             ) == {:error, :factor_changed}
    end
  end

  describe "confirm_oidc_identity_step_up/3" do
    test "consumes an inbox code once", %{provider: provider, subject: subject} do
      assert {:ok, :email} =
               Auth.begin_oidc_identity_step_up(
                 provider.id,
                 provider.name,
                 subject
               )

      assert_received {:email, email}
      code = Fixtures.Auth.code_from_email(email)

      assert {:ok, _proof} =
               Auth.confirm_oidc_identity_step_up(provider.id, code, subject)

      assert Auth.confirm_oidc_identity_step_up(provider.id, code, subject) ==
               {:error, :invalid}
    end

    test "a code issued for one provider does not confirm another", %{
      account: account,
      provider: provider,
      subject: subject
    } do
      other =
        Fixtures.SSO.create_identity_provider(
          account_id: account.id,
          kind: :openid_connect
        )

      assert {:ok, :email} =
               Auth.begin_oidc_identity_step_up(
                 provider.id,
                 provider.name,
                 subject
               )

      assert_received {:email, email}
      code = Fixtures.Auth.code_from_email(email)

      assert Auth.confirm_oidc_identity_step_up(other.id, code, subject) ==
               {:error, :invalid}
    end
  end

  describe "verify_oidc_identity_step_up_proof/3" do
    test "a proof is bound to the Member row it was confirmed for",
         %{account: account, member: member, provider: provider} = context do
      proof = local_proof(context)
      assert Auth.verify_oidc_identity_step_up_proof(proof, provider.id, member) == :ok

      other_member = Fixtures.Memberships.create_membership(account_id: account.id)

      assert Auth.verify_oidc_identity_step_up_proof(proof, provider.id, other_member) ==
               {:error, :identity_step_up_stale}

      renamed = Fixtures.Memberships.sync_display_name(member, "Changed Since")

      assert Auth.verify_oidc_identity_step_up_proof(proof, provider.id, renamed) ==
               {:error, :identity_step_up_stale}

      assert Auth.verify_oidc_identity_step_up_proof("garbage", provider.id, member) ==
               {:error, :identity_step_up_stale}
    end
  end

  describe "ensure_oidc_identity_step_up_current/5" do
    test "requires the exact still-live browser session",
         %{
           member: member,
           provider: provider,
           raw_session: raw_session,
           session_digest: session_digest
         } = context do
      proof = local_proof(context)

      assert :ok =
               Auth.ensure_oidc_identity_step_up_current(
                 Repo,
                 proof,
                 session_digest,
                 provider.id,
                 member
               )

      other_session = Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      assert Auth.ensure_oidc_identity_step_up_current(
               Repo,
               proof,
               Crypto.hash(other_session),
               provider.id,
               member
             ) == :ok

      assert :ok = Auth.revoke_session_tokens([raw_session], :dead_entry, %RequestContext{})

      assert Auth.ensure_oidc_identity_step_up_current(
               Repo,
               proof,
               session_digest,
               provider.id,
               member
             ) == {:error, :identity_step_up_stale}
    end
  end

  describe "provider_sign_in_verification_facts/2" do
    test "starts unverified and is scoped to the current account", %{
      provider: provider,
      subject: subject
    } do
      assert {:ok, %{status: :unverified, linked?: false}} =
               SSO.provider_sign_in_verification_facts(provider, subject)

      {_other_owner, _other_account, other_subject} =
        Fixtures.Subjects.owner_subject(%{plan: "enterprise"})

      assert SSO.provider_sign_in_verification_facts(provider, other_subject) ==
               {:error, :not_found}
    end

    test "a verifier's replacement seat inherits neither identity nor attribution, but the receipt remains valid",
         %{account: account, provider: provider, member: member} = context do
      _identity = link_identity(context)
      member = Repo.reload!(member)
      provider = Fixtures.SSO.verify_provider_sign_in(provider, member)

      provider =
        provider |> IdentityProvider.Changeset.update(%{enabled: false}) |> Repo.update!()

      Fixtures.Memberships.mark_membership_as_deleted(member)

      replacement =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          email: member.email,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(replacement)

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

  describe "begin_identity_link/5" do
    test "asks the IdP for a fresh sign-in and binds the ceremony to the Member and its session",
         %{
           account: account,
           member: member,
           provider: provider,
           session_digest: session_digest,
           subject: subject
         } = context do
      proof = local_proof(context)

      assert {:ok, begun} =
               SSO.begin_identity_link(
                 provider.id,
                 @redirect_uri,
                 proof,
                 session_digest,
                 subject
               )

      assert_receive {:identity_link_begin_options, options}
      assert options[:url_extension] == [{"prompt", "login"}, {"max_age", "0"}]
      assert begun.actor_membership_id == member.id
      assert begun.actor_session_token_digest == session_digest
      assert begun.account_id == account.id
      assert begun.provider_id == provider.id
      assert begun.local_proof == proof
      assert is_integer(begun.started_at)
    end

    test "refuses a provider that belongs to another account, a stale proof and a non-admin",
         %{account: account, provider: provider, session_digest: session_digest, subject: subject} =
           context do
      {_other_owner, other_account, _other_subject} =
        Fixtures.Subjects.owner_subject(%{plan: "enterprise"})

      foreign = Fixtures.SSO.create_identity_provider(account_id: other_account.id, name: "Other")
      proof = local_proof(context)

      assert SSO.begin_identity_link(
               foreign.id,
               @redirect_uri,
               proof,
               session_digest,
               subject
             ) == {:error, :not_found}

      other =
        Fixtures.SSO.create_identity_provider(
          account_id: account.id,
          kind: :openid_connect
        )

      assert SSO.begin_identity_link(
               other.id,
               @redirect_uri,
               proof,
               session_digest,
               subject
             ) == {:error, :identity_step_up_stale}

      operator = Fixtures.Memberships.create_membership(account_id: account.id)

      assert SSO.begin_identity_link(
               provider.id,
               @redirect_uri,
               proof,
               session_digest,
               Fixtures.Subjects.subject_for(operator)
             ) == {:error, :unauthorized}
    end
  end

  describe "complete_identity_link/4" do
    test "binds the identity to the acting Member, records the verified sign-in and leaves the session's provenance alone",
         %{
           account: account,
           member: member,
           provider: provider,
           raw_session: raw_session,
           session_digest: session_digest,
           subject: subject
         } = context do
      Repo.reload!(member)
      |> Fixtures.Memberships.sync_display_name("Workspace Linker")

      proof = local_proof(context)

      {:ok, begun} =
        SSO.begin_identity_link(
          provider.id,
          @redirect_uri,
          proof,
          session_digest,
          subject
        )

      assert {:ok, %{identity: identity, provider: verified}} =
               SSO.complete_identity_link(
                 callback("workforce|user"),
                 begun,
                 session_digest,
                 subject
               )

      assert identity.membership_id == subject.membership_id
      assert identity.provider_id == provider.id
      assert identity.created_by == :user
      assert identity.provisioned_via == :oidc_link
      assert verified.sign_in_verified_by_membership_id == member.id

      assert {:ok, [event], _} =
               Emisar.Audit.list_events(subject,
                 filter: [event_type: ["sso.identity_linked"]]
               )

      assert event.target_label == "Workspace Linker"

      assert {:ok, %UserToken{auth_method: :magic_link, user_identity_id: nil}} =
               Auth.fetch_session_by_token(raw_session, account.id)
    end

    test "fails closed when the provider subject belongs to another Member, live or removed",
         %{
           account: account,
           member: member,
           provider: provider,
           session_digest: session_digest,
           subject: subject
         } = context do
      other = Fixtures.Memberships.create_membership(account_id: account.id)

      _taken =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: other,
          provider_identifier: "workforce|taken"
        })

      removed = Fixtures.Memberships.create_membership(account_id: account.id)

      _left_behind =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: removed,
          provider_identifier: "workforce|removed"
        })

      Fixtures.Memberships.mark_membership_as_deleted(removed)

      for identifier <- ["workforce|taken", "workforce|removed"] do
        proof = local_proof(context)

        {:ok, begun} =
          SSO.begin_identity_link(
            provider.id,
            @redirect_uri,
            proof,
            session_digest,
            subject
          )

        assert SSO.complete_identity_link(
                 callback(identifier),
                 begun,
                 session_digest,
                 subject
               ) == {:error, :identity_already_linked}
      end

      refute Repo.exists?(
               UserIdentity.Query.not_deleted()
               |> UserIdentity.Query.by_provider_id(provider.id)
               |> UserIdentity.Query.by_membership_id(member.id)
             )

      refute Repo.reload!(provider).sign_in_verified_at
    end

    test "re-verifying rebinds the Member's own retired identity to the new subject",
         %{provider: provider, session_digest: session_digest, subject: subject} = context do
      identity = link_identity(context)
      Fixtures.SSO.retire_identity(identity)
      proof = local_proof(context)

      {:ok, begun} =
        SSO.begin_identity_link(
          provider.id,
          @redirect_uri,
          proof,
          session_digest,
          subject
        )

      assert {:ok, %{identity: relinked}} =
               SSO.complete_identity_link(
                 callback("workforce|user-again"),
                 begun,
                 session_digest,
                 subject
               )

      assert relinked.id == identity.id
      assert relinked.provider_identifier == "workforce|user-again"
      assert is_nil(relinked.provider_identifier_retired_at)
    end

    test "provider verification works while disabled and becomes stale after config changes",
         %{provider: provider, session_digest: session_digest, subject: subject} = context do
      disabled =
        provider
        |> IdentityProvider.Changeset.update(%{enabled: false})
        |> Repo.update!()

      context = %{context | provider: disabled}
      proof = local_proof(context)

      {:ok, begun} =
        SSO.begin_identity_link(
          disabled.id,
          @redirect_uri,
          proof,
          session_digest,
          subject
        )

      assert {:ok, %{provider: %IdentityProvider{enabled: false}}} =
               SSO.complete_identity_link(
                 callback("workforce|admin"),
                 begun,
                 session_digest,
                 subject
               )

      assert {:ok, %{status: :verified, linked?: true}} =
               SSO.provider_sign_in_verification_facts(disabled, subject)

      verified = Repo.reload!(disabled)
      assert verified.sign_in_verified_by_membership_id == subject.membership_id

      assert {:ok, enabled} = SSO.update_provider(disabled, %{enabled: true}, subject)
      assert enabled.enabled

      enabled
      |> IdentityProvider.Changeset.update(%{client_secret: "rotated-secret"})
      |> Repo.update!()

      assert {:ok, %{status: :stale}} =
               SSO.provider_sign_in_verification_facts(enabled, subject)
    end

    test "rejects a stash begun by another session or Member",
         %{
           account: account,
           member: member,
           provider: provider,
           session_digest: session_digest,
           subject: subject
         } = context do
      proof = local_proof(context)

      {:ok, begun} =
        SSO.begin_identity_link(
          provider.id,
          @redirect_uri,
          proof,
          session_digest,
          subject
        )

      other_session = Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      assert SSO.complete_identity_link(
               callback("workforce|user"),
               begun,
               Crypto.hash(other_session),
               subject
             ) == {:error, :identity_link_invalid}

      other_admin = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      other_subject = Fixtures.Subjects.subject_for(other_admin)

      assert SSO.complete_identity_link(
               callback("workforce|user"),
               begun,
               session_digest,
               other_subject
             ) == {:error, :identity_link_invalid}

      refute Repo.exists?(
               UserIdentity.Query.not_deleted()
               |> UserIdentity.Query.by_provider_id(provider.id)
             )
    end

    test "rejects a stale IdP auth_time and a session revoked during the round trip",
         %{
           provider: provider,
           raw_session: raw_session,
           session_digest: session_digest,
           subject: subject
         } = context do
      proof = local_proof(context)

      {:ok, begun} =
        SSO.begin_identity_link(
          provider.id,
          @redirect_uri,
          proof,
          session_digest,
          subject
        )

      stale_callback =
        callback("workforce|user")
        |> put_in(["_claims", "auth_time"], begun.started_at - 300)

      assert SSO.complete_identity_link(
               stale_callback,
               begun,
               session_digest,
               subject
             ) == {:error, :identity_link_invalid}

      no_auth_time =
        update_in(callback("workforce|user"), ["_claims"], &Map.delete(&1, "auth_time"))

      assert SSO.complete_identity_link(
               no_auth_time,
               begun,
               session_digest,
               subject
             ) == {:error, :identity_link_invalid}

      assert :ok = Auth.revoke_session_tokens([raw_session], :dead_entry, %RequestContext{})

      assert SSO.complete_identity_link(
               callback("workforce|user"),
               begun,
               session_digest,
               subject
             ) == {:error, :unauthorized}
    end

    test "rechecks administrator authority at the provider callback",
         %{member: member, provider: provider, session_digest: session_digest, subject: subject} =
           context do
      proof = local_proof(context)

      {:ok, begun} =
        SSO.begin_identity_link(
          provider.id,
          @redirect_uri,
          proof,
          session_digest,
          subject
        )

      membership = Repo.reload!(member)
      _membership = Fixtures.Memberships.force_role(membership, "viewer")

      assert SSO.complete_identity_link(
               callback("workforce|admin"),
               begun,
               session_digest,
               subject
             ) == {:error, :unauthorized}

      refute Repo.reload!(provider).sign_in_verified_at
    end
  end

  defp local_proof(context) do
    assert {:ok, :email} =
             Auth.begin_oidc_identity_step_up(
               context.provider.id,
               context.provider.name,
               context.subject
             )

    assert_received {:email, email}
    code = Fixtures.Auth.code_from_email(email)

    assert {:ok, proof} =
             Auth.confirm_oidc_identity_step_up(context.provider.id, code, context.subject)

    proof
  end

  defp link_identity(context) do
    proof = local_proof(context)

    {:ok, begun} =
      SSO.begin_identity_link(
        context.provider.id,
        @redirect_uri,
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
