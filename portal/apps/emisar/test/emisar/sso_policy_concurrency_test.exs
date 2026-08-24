defmodule Emisar.SSOPolicyConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Auth, Config, Fixtures, Repo, RequestContext, SSO}
  alias Emisar.Accounts.Account
  alias Emisar.SSO.{IdentityProvider, LinkRequest}
  alias Emisar.Users.User

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
      blocker = email_blocker(context.callback_claims["email"], parent)

      try do
        assert_receive {:email_inserted, blocker_backend}, 5_000

        callback =
          unboxed_task(fn ->
            Config.put_override(:emisar, :sso_oidc_impl, StubOIDC)
            send(parent, {:callback_backend, backend_pid()})
            SSO.complete_auth(context.provider, %{"_claims" => context.callback_claims}, %{})
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

            send(blocker.pid, :rollback)
            assert {:error, :released} = Task.await(blocker, 30_000)

            assert {:ok, %{identity: identity, created?: true}} =
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
        send(blocker.pid, :rollback)
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
              SSO.complete_auth(context.provider, %{"_claims" => context.callback_claims}, %{})
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

              Auth.complete_sso_account_sign_in(
                context.user,
                context.account.id,
                %RequestContext{},
                user_identity_id: context.identity.id
              )
            end)

          try do
            assert_receive {:minter_backend, minter_backend}, 5_000
            await_blocked_by(minter_backend, updater_backend)

            send(blocker.pid, :release)
            assert {:ok, :ok} = Task.await(blocker, 30_000)
            assert {:ok, %IdentityProvider{satisfies_mfa: false}} = Task.await(updater, 30_000)
            assert {:ok, token, false} = Task.await(minter, 30_000)

            case Auth.fetch_user_and_token_by_session_token(token) do
              {:ok, fetched_user, session} ->
                assert fetched_user.id == context.user.id
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

            Auth.complete_sso_account_sign_in(
              context.user,
              context.account.id,
              %RequestContext{},
              user_identity_id: context.identity.id
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
            assert Auth.fetch_user_and_token_by_session_token(token) == {:error, :not_found}
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

  test "a committed email change defeats a waiting synthesized-identity convergence" do
    unboxed_sso(fn context ->
      Repo.delete!(context.identity)

      identifier = "directory-#{Ecto.UUID.generate()}"

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: context.account.id,
          provider_id: context.provider.id,
          user_id: context.user.id,
          provider_identifier: identifier,
          scim_external_id: identifier,
          provisioned_via: :scim
        })

      claims = %{
        "sub" => identifier,
        "email" => context.user.email,
        "email_verified" => true
      }

      parent = self()
      updater = user_email_update_blocker(context.user, "changed-#{context.user.email}", parent)

      try do
        assert_receive {:user_email_changed, updater_backend}, 5_000

        callback =
          unboxed_task(fn ->
            Config.put_override(:emisar, :sso_oidc_impl, StubOIDC)
            send(parent, {:callback_backend, backend_pid()})
            SSO.complete_auth(context.provider, %{"_claims" => claims}, %{})
          end)

        try do
          assert_receive {:callback_backend, callback_backend}, 5_000
          await_blocked_by(callback_backend, updater_backend)

          send(updater.pid, :commit)
          assert {:ok, %User{}} = Task.await(updater, 30_000)

          assert {:pending, %LinkRequest{matched_user_id: nil, email: email}} =
                   Task.await(callback, 30_000)

          assert email == claims["email"]
          assert Repo.reload!(identity).last_seen_at == identity.last_seen_at
        after
          stop_tasks([callback])
        end
      after
        send(updater.pid, :commit)
        stop_tasks([updater])
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

            SSO.approve_link_request(
              request,
              Accounts.RunnerAccess.none(),
              context.subject
            )
          end)

        try do
          assert_receive {:approval_backend, approval_backend}, 5_000
          await_blocked_by(approval_backend, updater_backend)

          send(updater.pid, :commit)
          assert {:ok, %IdentityProvider{}} = Task.await(updater, 30_000)
          assert Task.await(approval, 30_000) == {:error, :identity_namespace_changed}
          assert Repo.reload!(request)
          assert Emisar.Users.fetch_user_by_email(request_email) == {:error, :not_found}
        after
          stop_tasks([approval])
        end
      after
        send(updater.pid, :commit)
        stop_tasks([updater])
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

  defp email_blocker(email, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        _user = Fixtures.Users.create_user(%{email: email})
        send(parent, {:email_inserted, backend_pid()})

        receive do
          :rollback -> Repo.rollback(:released)
        end
      end)
    end)
  end

  defp user_email_update_blocker(user, new_email, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        locked =
          User.Query.not_deleted()
          |> User.Query.by_id(user.id)
          |> User.Query.lock_for_update()
          |> Repo.fetch!(User.Query)

        updated =
          locked
          |> Ecto.Changeset.change(email: new_email, confirmed_at: nil)
          |> Repo.update!()

        send(parent, {:user_email_changed, backend_pid()})

        receive do
          :commit -> updated
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

  defp unboxed_sso(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      user = Fixtures.Users.create_user(%{email: "sso-mfa-race-#{suffix}@example.test"})
      callback_email = "sso-callback-race-#{suffix}@example.test"

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "SSO MFA race #{suffix}", slug: "sso-mfa-race-#{suffix}"},
          user
        )

      _subscription = Fixtures.Accounts.create_subscription(account, "enterprise")
      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      provider =
        Fixtures.SSO.create_identity_provider(%{
          account_id: account.id,
          satisfies_mfa: true
        })

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          user_id: user.id
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
          user: user
        })
      after
        Repo.delete_all(from(stored in Account, where: stored.id == ^account.id))

        Repo.delete_all(
          from(stored in User,
            where: stored.id == ^user.id or stored.email == ^callback_email
          )
        )
      end
    end)
  end

  defp unboxed_task(fun) do
    Task.async(fn ->
      Process.delete(:"$callers")
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        :ok = Sandbox.checkin(Repo)
      end
    end)
  end

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp stop_tasks(tasks) do
    Enum.each(tasks, fn task ->
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end)
  end

  defp await_blocked_by(
         blocked_backend,
         blocking_backend,
         deadline \\ System.monotonic_time(:millisecond) + 10_000
       ) do
    query = "SELECT $2::integer = ANY(pg_blocking_pids($1::integer))"

    cond do
      Repo.query!(query, [blocked_backend, blocking_backend]).rows == [[true]] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("backend #{blocked_backend} was never blocked by backend #{blocking_backend}")

      true ->
        await_blocked_by(blocked_backend, blocking_backend, deadline)
    end
  end
end
