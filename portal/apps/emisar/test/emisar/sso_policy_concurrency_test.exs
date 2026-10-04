defmodule Emisar.SSOPolicyConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Auth, Config, Crypto, Fixtures, Repo, RequestContext, SSO}
  alias Emisar.Accounts.{Account, Membership}
  alias Emisar.SSO.{IdentityProvider, LinkRequest, UserIdentity}

  @moduletag timeout: 60_000

  defmodule StubOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl Emisar.SSO.OIDC
    def begin_authorization(_provider, _opts), do: {:error, :not_used}

    @impl Emisar.SSO.OIDC
    def verify_callback(_provider, %{"_claims" => claims}, _stash) do
      {:ok, %{identifier: claims["sub"], claims: claims}}
    end
  end

  test "callback-first holds current provider policy through the identity write" do
    unboxed_sso(fn context ->
      parent = self()
      blocker = provider_blocker(context.provider, parent)

      try do
        assert_receive {:provider_locked, blocker_backend}, 5_000

        callback =
          unboxed_task(fn ->
            Config.put_override(:emisar, :sso_oidc_impl, StubOIDC)
            send(parent, {:callback_backend, backend_pid()})

            SSO.complete_auth(
              context.provider,
              %{"_claims" => context.callback_claims},
              %{},
              %RequestContext{}
            )
          end)

        try do
          assert_receive {:callback_backend, callback_backend}, 5_000
          await_blocked_by(callback_backend, blocker_backend)

          updater =
            unboxed_task(fn ->
              send(parent, {:updater_backend, backend_pid()})
              SSO.update_provider(context.provider, %{provisioner: :manual}, context.subject)
            end)

          try do
            assert_receive {:updater_backend, updater_backend}, 5_000
            await_blocked_by(updater_backend, callback_backend)

            send(blocker.pid, :release)
            assert {:ok, :ok} = Task.await(blocker, 30_000)

            assert {:ok, %{membership: %Membership{}, identity: identity}} =
                     Task.await(callback, 30_000)

            assert identity.provider_identifier == context.callback_claims["sub"]
            assert {:ok, %IdentityProvider{provisioner: :manual}} = Task.await(updater, 30_000)
          after
            stop_tasks([updater])
          end
        after
          stop_tasks([callback])
        end
      after
        send(blocker.pid, :release)
        stop_tasks([blocker])
      end
    end)
  end

  test "provider-update-first makes the waiting callback obey current manual policy" do
    unboxed_sso(fn context ->
      parent = self()
      blocker = provider_blocker(context.provider, parent)

      try do
        assert_receive {:provider_locked, blocker_backend}, 5_000

        updater =
          unboxed_task(fn ->
            send(parent, {:updater_backend, backend_pid()})
            SSO.update_provider(context.provider, %{provisioner: :manual}, context.subject)
          end)

        try do
          assert_receive {:updater_backend, updater_backend}, 5_000
          await_blocked_by(updater_backend, blocker_backend)

          callback =
            unboxed_task(fn ->
              Config.put_override(:emisar, :sso_oidc_impl, StubOIDC)
              send(parent, {:callback_backend, backend_pid()})

              SSO.complete_auth(
                context.provider,
                %{"_claims" => context.callback_claims},
                %{},
                %RequestContext{}
              )
            end)

          try do
            assert_receive {:callback_backend, callback_backend}, 5_000
            await_blocked_by(callback_backend, updater_backend)

            send(blocker.pid, :release)
            assert {:ok, :ok} = Task.await(blocker, 30_000)
            assert {:ok, %IdentityProvider{provisioner: :manual}} = Task.await(updater, 30_000)

            assert {:pending, %LinkRequest{provider_identifier: identifier}} =
                     Task.await(callback, 30_000)

            assert identifier == context.callback_claims["sub"]
          after
            stop_tasks([callback])
          end
        after
          stop_tasks([updater])
        end
      after
        send(blocker.pid, :release)
        stop_tasks([blocker])
      end
    end)
  end

  test "an invitation that commits the address first parks the waiting JIT sign-in for approval" do
    unboxed_sso(fn context ->
      parent = self()
      email = context.callback_claims["email"]
      invitation = staged_invitation(context, email, parent)

      try do
        assert_receive {:invitation_staged, invitation_backend}, 5_000

        callback =
          unboxed_task(fn ->
            Config.put_override(:emisar, :sso_oidc_impl, StubOIDC)
            send(parent, {:callback_backend, backend_pid()})

            SSO.complete_auth(
              context.provider,
              %{"_claims" => context.callback_claims},
              %{},
              %RequestContext{}
            )
          end)

        try do
          assert_receive {:callback_backend, callback_backend}, 5_000
          # The uncommitted invitation holds the workspace lock the callback
          # takes first, so its contact match runs only once the seat is
          # committed — and then sees it.
          await_blocked_by(callback_backend, invitation_backend)

          send(invitation.pid, :commit)
          assert {:ok, %Membership{} = invited} = Task.await(invitation, 30_000)
          assert {:pending, %LinkRequest{} = request} = Task.await(callback, 30_000)
          assert request.matched_membership_id == invited.id
          assert request.provider_identifier == context.callback_claims["sub"]

          assert Accounts.peek_sync_membership_by_email(context.account.id, email).id ==
                   invited.id

          assert membership_count(context.account) == 2

          refute UserIdentity.Query.not_deleted()
                 |> UserIdentity.Query.by_provider_and_identifier(
                   context.provider.id,
                   context.callback_claims["sub"]
                 )
                 |> Repo.exists?()

          assert [%LinkRequest{id: parked_id}] =
                   LinkRequest.Query.all()
                   |> LinkRequest.Query.by_provider_id(context.provider.id)
                   |> Repo.all()

          assert parked_id == request.id
        after
          stop_tasks([callback])
        end
      after
        send(invitation.pid, :commit)
        stop_tasks([invitation])
      end
    end)
  end

  test "downgrade-first makes a later session use current untrusted MFA policy" do
    unboxed_sso(fn context ->
      parent = self()
      blocker = provider_blocker(context.provider, parent)

      try do
        assert_receive {:provider_locked, blocker_backend}, 5_000

        updater =
          unboxed_task(fn ->
            send(parent, {:updater_backend, backend_pid()})
            SSO.update_provider(context.provider, %{satisfies_mfa: false}, context.subject)
          end)

        try do
          assert_receive {:updater_backend, updater_backend}, 5_000
          await_blocked_by(updater_backend, blocker_backend)

          minter =
            unboxed_task(fn ->
              send(parent, {:minter_backend, backend_pid()})

              Auth.complete_sso_sign_in(
                context.owner,
                context.identity,
                context.provider,
                Crypto.random_secret(),
                %RequestContext{}
              )
            end)

          try do
            assert_receive {:minter_backend, minter_backend}, 5_000
            await_blocked_by(minter_backend, updater_backend)

            send(blocker.pid, :release)
            assert {:ok, :ok} = Task.await(blocker, 30_000)
            assert {:ok, %IdentityProvider{satisfies_mfa: false}} = Task.await(updater, 30_000)
            assert {:ok, token, false} = Task.await(minter, 30_000)

            case Auth.fetch_session_by_token(token, context.account.id) do
              {:ok, session} ->
                assert session.membership_id == context.owner.id
                refute session.mfa_verified_at

              {:error, :not_found} ->
                :ok
            end
          after
            stop_tasks([minter])
          end
        after
          stop_tasks([updater])
        end
      after
        send(blocker.pid, :release)
        stop_tasks([blocker])
      end
    end)
  end

  test "mint-first lets the committed downgrade revoke the trusted session" do
    unboxed_sso(fn context ->
      parent = self()
      blocker = provider_blocker(context.provider, parent)

      try do
        assert_receive {:provider_locked, blocker_backend}, 5_000

        minter =
          unboxed_task(fn ->
            send(parent, {:minter_backend, backend_pid()})

            Auth.complete_sso_sign_in(
              context.owner,
              context.identity,
              context.provider,
              Crypto.random_secret(),
              %RequestContext{}
            )
          end)

        try do
          assert_receive {:minter_backend, minter_backend}, 5_000
          await_blocked_by(minter_backend, blocker_backend)

          updater =
            unboxed_task(fn ->
              send(parent, {:updater_backend, backend_pid()})
              SSO.update_provider(context.provider, %{satisfies_mfa: false}, context.subject)
            end)

          try do
            assert_receive {:updater_backend, updater_backend}, 5_000
            await_blocked_by(updater_backend, minter_backend)

            send(blocker.pid, :release)
            assert {:ok, :ok} = Task.await(blocker, 30_000)
            assert {:ok, token, true} = Task.await(minter, 30_000)
            assert {:ok, %IdentityProvider{satisfies_mfa: false}} = Task.await(updater, 30_000)
            # The downgrade ends the connection's sessions: a session minted
            # under the trusted policy never outlives the policy change.
            assert Auth.fetch_session_by_token(token, context.account.id) ==
                     {:error, :not_found}
          after
            stop_tasks([updater])
          end
        after
          stop_tasks([minter])
        end
      after
        send(blocker.pid, :release)
        stop_tasks([blocker])
      end
    end)
  end

  test "a namespace update that wins the provider lock defeats a stale link approval" do
    unboxed_sso(fn context ->
      request_email = "pending-#{Ecto.UUID.generate()}@example.test"

      request =
        Fixtures.SSO.create_link_request(
          provider: context.provider,
          provider_identifier: "pending-#{Ecto.UUID.generate()}",
          source: :oidc,
          namespace_fingerprint: SSO.Provisioning.namespace_fingerprint(context.provider),
          email: request_email,
          claims: %{
            "sub" => "pending-subject",
            "email" => request_email,
            "email_verified" => true
          }
        )

      parent = self()
      updater = provider_namespace_update_blocker(context.provider, parent)

      try do
        assert_receive {:provider_namespace_changed, updater_backend}, 5_000

        approval =
          unboxed_task(fn ->
            send(parent, {:approval_backend, backend_pid()})

            SSO.approve_link_request(request, Accounts.RunnerAccess.none(), context.subject)
          end)

        try do
          assert_receive {:approval_backend, approval_backend}, 5_000
          await_blocked_by(approval_backend, updater_backend)

          send(updater.pid, :commit)
          assert {:ok, %IdentityProvider{}} = Task.await(updater, 30_000)
          assert Task.await(approval, 30_000) == {:error, :identity_namespace_changed}
          assert Repo.reload!(request)
          assert Accounts.peek_sync_membership_by_email(context.account.id, request_email) == nil
        after
          stop_tasks([approval])
        end
      after
        send(updater.pid, :commit)
        stop_tasks([updater])
      end
    end)
  end

  test "a matched approval takes the account lock before the provider lock" do
    unboxed_sso(fn context ->
      request =
        Fixtures.SSO.create_link_request(
          provider: context.provider,
          provider_identifier: "matched-order-#{Ecto.UUID.generate()}",
          source: :oidc,
          namespace_fingerprint: SSO.Provisioning.namespace_fingerprint(context.provider),
          email: context.owner.email,
          claims: %{
            "sub" => "matched-order-subject",
            "email" => context.owner.email,
            "email_verified" => true
          },
          matched_membership_id: context.subject.membership_id
        )

      parent = self()
      account_blocker = account_blocker(context.account, parent)

      try do
        assert_receive {:account_locked, account_backend}, 5_000

        approval =
          unboxed_task(fn ->
            send(parent, {:matched_approval_backend, backend_pid()})

            SSO.approve_link_request(request, Accounts.RunnerAccess.none(), context.subject)
          end)

        try do
          assert_receive {:matched_approval_backend, approval_backend}, 5_000
          await_blocked_by(approval_backend, account_backend)

          provider_blocker = provider_blocker(context.provider, parent)

          try do
            # If approval took provider first, this lock could not be acquired
            # while approval waits on the account row.
            assert_receive {:provider_locked, provider_backend}, 5_000

            send(account_blocker.pid, :release)
            assert {:ok, :ok} = Task.await(account_blocker, 30_000)
            await_blocked_by(approval_backend, provider_backend)

            send(provider_blocker.pid, :release)
            assert {:ok, :ok} = Task.await(provider_blocker, 30_000)
            assert {:ok, %{identity: %SSO.UserIdentity{}}} = Task.await(approval, 30_000)
          after
            send(provider_blocker.pid, :release)
            stop_tasks([provider_blocker])
          end
        after
          stop_tasks([approval])
        end
      after
        send(account_blocker.pid, :release)
        stop_tasks([account_blocker])
      end
    end)
  end

  defp provider_blocker(provider, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        IdentityProvider.Query.not_deleted()
        |> IdentityProvider.Query.by_id(provider.id)
        |> IdentityProvider.Query.lock_for_update()
        |> Repo.fetch!(IdentityProvider.Query)

        send(parent, {:provider_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  defp account_blocker(account, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        Account.Query.not_deleted()
        |> Account.Query.by_id(account.id)
        |> Account.Query.lock_for_update()
        |> Repo.fetch!(Account.Query)

        send(parent, {:account_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  defp provider_namespace_update_blocker(provider, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        locked =
          IdentityProvider.Query.not_deleted()
          |> IdentityProvider.Query.by_id(provider.id)
          |> IdentityProvider.Query.lock_for_update()
          |> Repo.fetch!(IdentityProvider.Query)

        updated =
          locked
          |> Ecto.Changeset.change(issuer: "https://changed-#{Ecto.UUID.generate()}.test")
          |> Repo.update!()

        send(parent, {:provider_namespace_changed, backend_pid()})

        receive do
          :commit -> updated
        end
      end)
    end)
  end

  # Inviting takes the workspace lock first, like every Member transition, so
  # the uncommitted seat holds the callback at that lock until it commits; the
  # unique index on the address stays the backstop behind it.
  defp staged_invitation(context, email, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        {:ok, %{membership: invitation}} =
          Accounts.invite_user_to_account(
            Fixtures.Accounts.invitation_attrs(email: email),
            context.subject
          )

        send(parent, {:invitation_staged, backend_pid()})

        receive do
          :commit -> invitation
        end
      end)
    end)
  end

  defp membership_count(account) do
    from(membership in Membership, where: membership.account_id == ^account.id)
    |> Repo.aggregate(:count)
  end

  defp unboxed_sso(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      callback_email = "sso-callback-race-#{suffix}@example.test"

      account =
        Fixtures.Accounts.create_account(%{
          name: "SSO MFA race #{suffix}",
          slug: "sso-mfa-race-#{suffix}"
        })

      owner =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "owner",
          email: "sso-mfa-race-#{suffix}@example.test"
        )

      {:ok, _policy} = Emisar.Policies.seed_policy(account.id, owner.id)
      _subscription = Fixtures.Accounts.create_subscription(account, "enterprise")
      subject = Fixtures.Subjects.subject_for(owner)

      provider =
        Fixtures.SSO.create_identity_provider(%{
          account_id: account.id,
          satisfies_mfa: true
        })

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: owner
        })

      try do
        fun.(%{
          account: account,
          callback_claims: %{
            "sub" => "sso-callback-race-#{suffix}",
            "email" => callback_email,
            "email_verified" => true
          },
          identity: identity,
          provider: provider,
          subject: subject,
          owner: owner
        })
      after
        Repo.delete_all(from(stored in Account, where: stored.id == ^account.id))
      end
    end)
  end
end
