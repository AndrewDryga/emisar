defmodule Emisar.SSOIdentityLinkTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Audit, Auth, Crypto, Fixtures, Repo, SSO}
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
    {user, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id, name: "Workforce")
    raw_session = Fixtures.Auth.create_session_token!(user, :magic_link, nil)

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
                 NimbleTOTP.verification_code(secret),
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

      assert :ok =
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
      refute Map.has_key?(facts, :issuer)
      refute Map.has_key?(facts, :client_id)
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
  end

  describe "begin_identity_link/6" do
    test "links only the current user and leaves the current session provenance unchanged",
         %{provider: _provider, subject: _subject, user: _user} = context do
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

      assert identity.user_id == context.user.id
      assert identity.provider_id == context.provider.id
      assert identity.created_by == :user
      assert identity.provisioned_via == :oidc_link

      assert {:ok, _user, %UserToken{auth_method: :magic_link, user_identity_id: nil}} =
               Auth.fetch_user_and_token_by_session_token(context.raw_session)
    end
  end

  describe "complete_identity_link/4" do
    test "fails closed when the provider subject belongs to another user",
         %{account: _account, provider: _provider, subject: _subject, user: _user} = context do
      other = Fixtures.Users.create_user()

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
               |> UserIdentity.Query.by_user_id(context.user.id)
             )
    end

    test "provider verification works while disabled and becomes stale after config changes",
         %{provider: _provider, subject: _subject} = context do
      disabled =
        context.provider
        |> IdentityProvider.Changeset.update(%{enabled: false})
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
             ) == {:error, :identity_step_up_stale}
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
    test "removes the binding and only revokes sessions created through it",
         %{provider: _provider, subject: _subject, user: _user} = context do
      identity = link_identity(context)

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
      assert Auth.fetch_user_and_token_by_session_token(provider_session) == {:error, :not_found}
      assert {:ok, _user, _token} = Auth.fetch_user_and_token_by_session_token(unrelated_session)

      assert {:ok, _user, _token} =
               Auth.fetch_user_and_token_by_session_token(context.raw_session)
    end

    test "does not strand a membership when its account requires SSO",
         %{account: account, subject: _subject} = context do
      identity = link_identity(context)
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
