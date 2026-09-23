defmodule Emisar.SSOPolicyConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Auth, Config, Crypto, Fixtures, Repo, RequestContext, SSO}
  alias Emisar.Accounts.{Account, Membership}
  alias Emisar.SSO.{IdentityProvider, LinkRequest, UserIdentity}
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

  defmodule RecordingSessionDisconnector do
    def disconnect_live_sessions(topics) do
      owner = Emisar.Config.fetch_env!(:emisar, :retirement_disconnect_test_pid)
      send(owner, {:retirement_disconnect, topics, Emisar.Repo.in_transaction?()})
    end
  end

  defmodule StepUpOIDC do
    @behaviour Emisar.SSO.OIDC

    @impl true
    def begin_authorization(_provider, _opts) do
      {:ok, %{authorize_url: "https://idp.test/auth", state: "s", nonce: "n", pkce_verifier: "v"}}
    end

    @impl true
    def verify_callback(_provider, %{"sub" => identifier}, _stash) do
      parent = Config.fetch_env!(:emisar, :retirement_disconnect_test_pid)
      send(parent, {:step_up_oidc_verified, self()})
      {:ok, %{identifier: identifier, claims: %{"sub" => identifier}}}
    end
  end

  describe "put_session_step_up_authority/4" do
    for target <- [:origin, :sibling] do
      @target target
      @tag :session_step_up_race
      test "#{target} revocation after OIDC preflight wins before the waiting rotation" do
        unboxed_step_up(fn context ->
          {member, owner} =
            if @target == :origin,
              do: {context.origin_member, context.origin_owner},
              else: {context.sibling_member, context.sibling_owner}

          parent = self()
          blocker = membership_blocker(member, parent)

          try do
            assert_receive {:membership_locked, blocker_backend}, 5_000

            revoker =
              unboxed_task(fn ->
                configure_step_up_worker(parent)
                send(parent, {:revoker_backend, backend_pid()})
                Accounts.end_all_sessions_for(member, owner)
              end)

            try do
              assert_receive {:revoker_backend, revoker_backend}, 5_000
              await_blocked_by(revoker_backend, blocker_backend)
              callback = step_up_task(context, parent, :callback_backend)

              try do
                assert_receive {:callback_backend, callback_backend}, 5_000
                assert_receive {:step_up_oidc_verified, _pid}, 5_000
                await_blocked_by(callback_backend, revoker_backend)
                send(blocker.pid, :release)
                assert {:ok, _member} = Task.await(blocker, 30_000)
                assert Task.await(revoker, 30_000) == :ok

                case @target do
                  :origin ->
                    assert Task.await(callback, 30_000) == {:error, :unauthorized}

                    assert {:ok, _, donor} =
                             Auth.fetch_user_and_token_by_session_token(context.raw)

                    assert Auth.session_membership_ids(context.user.id, donor) == [
                             context.sibling_member.id
                           ]

                    assert step_up_audit_count(context.account) == 0
                    assert step_up_audit_count(context.sibling) == 0

                  :sibling ->
                    assert {:ok, result} = Task.await(callback, 30_000)

                    assert {:ok, _, replacement} =
                             Auth.fetch_user_and_token_by_session_token(result.token)

                    assert Auth.session_membership_ids(context.user.id, replacement) == [
                             context.origin_member.id
                           ]

                    assert step_up_audit_count(context.account) == 1
                end

                assert target_session_count(context.user) == context.session_count
                topic = Auth.live_socket_topic_for_session(context.raw)
                assert_received {:retirement_disconnect, topics, false}
                assert topic in topics
              after
                stop_tasks([callback])
              end
            after
              stop_tasks([revoker])
            end
          after
            send(blocker.pid, :release)
            stop_tasks([blocker])
          end
        end)
      end
    end

    @tag :session_step_up_race
    test "rotation first lets a waiting sibling revoke remove proof from the replacement bearer" do
      unboxed_step_up(fn context ->
        parent = self()
        blocker = user_no_key_update_blocker(context.user, parent)

        try do
          assert_receive {:user_no_key_update_locked, blocker_backend}, 5_000
          callback = step_up_task(context, parent, :callback_backend)

          try do
            assert_receive {:callback_backend, callback_backend}, 5_000
            assert_receive {:step_up_oidc_verified, _pid}, 5_000
            await_blocked_by(callback_backend, blocker_backend)

            revoker =
              unboxed_task(fn ->
                configure_step_up_worker(parent)
                send(parent, {:revoker_backend, backend_pid()})
                Accounts.end_all_sessions_for(context.sibling_member, context.sibling_owner)
              end)

            try do
              assert_receive {:revoker_backend, revoker_backend}, 5_000
              await_blocked_by(revoker_backend, callback_backend)
              send(blocker.pid, :release)
              assert {:ok, :ok} = Task.await(blocker, 30_000)
              assert {:ok, result} = Task.await(callback, 30_000)
              assert Task.await(revoker, 30_000) == :ok

              assert {:ok, _, replacement} =
                       Auth.fetch_user_and_token_by_session_token(result.token)

              assert Auth.fetch_user_and_token_by_session_token(context.raw) ==
                       {:error, :not_found}

              assert Auth.session_membership_ids(context.user.id, replacement) == [
                       context.origin_member.id
                     ]

              routes = Auth.MemberGrantRoute.Query.by_token_id(replacement.id) |> Repo.all()
              assert length(routes) == 2
              original = Enum.find(context.routes, &(&1.account_id == context.account.id))
              assert original in routes
              assert step_up_audit_count(context.account) == 1
              assert step_up_audit_count(context.sibling) == 1
              assert target_session_count(context.user) == context.session_count
              old_topic = Auth.live_socket_topic_for_session(context.raw)
              new_topic = Auth.live_socket_topic_for_session(result.token)
              assert_received {:retirement_disconnect, [^old_topic], false}
              assert_received {:retirement_disconnect, [^new_topic], false}
              refute_received {:retirement_disconnect, _, _}
            after
              stop_tasks([revoker])
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

    @tag :session_step_up_race
    test "two preflighted callbacks consume a donor exactly once" do
      unboxed_step_up(fn context ->
        parent = self()
        blocker = user_no_key_update_blocker(context.user, parent)

        try do
          assert_receive {:user_no_key_update_locked, blocker_backend}, 5_000
          first = step_up_task(context, parent, :first_backend)

          try do
            assert_receive {:first_backend, first_backend}, 5_000
            assert_receive {:step_up_oidc_verified, _pid}, 5_000
            await_blocked_by(first_backend, blocker_backend)
            second = step_up_task(context, parent, :second_backend)

            try do
              assert_receive {:second_backend, second_backend}, 5_000
              assert_receive {:step_up_oidc_verified, _pid}, 5_000
              await_blocked_by(second_backend, first_backend)
              send(blocker.pid, :release)
              assert {:ok, :ok} = Task.await(blocker, 30_000)
              assert {:ok, result} = Task.await(first, 30_000)
              assert Task.await(second, 30_000) == {:error, :unauthorized}

              assert {:ok, _, replacement} =
                       Auth.fetch_user_and_token_by_session_token(result.token)

              assert Auth.fetch_user_and_token_by_session_token(context.raw) ==
                       {:error, :not_found}

              assert target_session_count(context.user) == context.session_count
              routes = Auth.MemberGrantRoute.Query.by_token_id(replacement.id) |> Repo.all()
              assert length(routes) == 3
              assert Enum.all?(context.routes, &(&1 in routes))
              assert step_up_audit_count(context.account) == 1
              assert step_up_audit_count(context.sibling) == 1
              topic = Auth.live_socket_topic_for_session(context.raw)
              assert_received {:retirement_disconnect, [^topic], false}
              refute_received {:retirement_disconnect, _, _}
            after
              stop_tasks([second])
            end
          after
            stop_tasks([first])
          end
        after
          send(blocker.pid, :release)
          stop_tasks([blocker])
        end
      end)
    end
  end

  @tag :other_sessions_rotation_race
  test "signing out other sessions retires a replacement whose rotation was already committing" do
    unboxed_step_up(fn context ->
      assert {:ok, keeper} = Auth.fetch_current_session(context.subject)
      keeper_id = keeper.id
      parent = self()
      blocker = session_grant_blocker(context.raw, parent)

      try do
        assert_receive {:session_grants_locked, blocker_backend}, 5_000
        callback = step_up_task(context, parent, :callback_backend)

        try do
          assert_receive {:callback_backend, callback_backend}, 5_000
          assert_receive {:step_up_oidc_verified, _pid}, 5_000
          await_blocked_by(callback_backend, blocker_backend)

          revoker =
            unboxed_task(fn ->
              configure_step_up_worker(parent)
              send(parent, {:revoker_backend, backend_pid()})
              Auth.revoke_and_disconnect_other_sessions(keeper.token, context.subject)
            end)

          try do
            assert_receive {:revoker_backend, revoker_backend}, 5_000
            await_blocked_by(revoker_backend, callback_backend)
            send(blocker.pid, :release)
            assert {:ok, :ok} = Task.await(blocker, 30_000)
            assert {:ok, result} = Task.await(callback, 30_000)
            assert {:ok, count} = Task.await(revoker, 30_000)
            assert count == context.session_count - 1
            assert target_session_count(context.user) == 1

            assert {:ok, %Auth.UserToken{id: ^keeper_id}} =
                     Auth.fetch_current_session(context.subject)

            assert Auth.fetch_user_and_token_by_session_token(result.token) ==
                     {:error, :not_found}

            assert Auth.fetch_user_and_token_by_session_token(context.raw) == {:error, :not_found}
            old_topic = Auth.live_socket_topic_for_session(context.raw)
            new_topic = Auth.live_socket_topic_for_session(result.token)
            assert_received {:retirement_disconnect, [^old_topic], false}
            assert_received {:retirement_disconnect, topics, false}
            assert new_topic in topics
          after
            stop_tasks([revoker])
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

  defp configure_step_up_worker(parent) do
    Config.put_override(:emisar, :sso_oidc_impl, StepUpOIDC)
    Config.put_override(:emisar, :retirement_disconnect_test_pid, parent)

    Config.put_override(
      :emisar,
      :session_disconnect_handler,
      {:emisar, RecordingSessionDisconnector}
    )
  end

  defp step_up_task(context, parent, backend_message) do
    unboxed_task(fn ->
      configure_step_up_worker(parent)
      send(parent, {backend_message, backend_pid()})

      SSO.complete_session_step_up(
        %{"sub" => context.identity.provider_identifier},
        context.stash,
        Crypto.hash(context.raw),
        context.donor_subject
      )
    end)
  end

  defp target_session_count(user) do
    Auth.UserToken.Query.by_user_id(user.id)
    |> Auth.UserToken.Query.by_context("session")
    |> Repo.aggregate(:count)
  end

  defp step_up_audit_count(account) do
    Emisar.Audit.Event.Query.all()
    |> Emisar.Audit.Event.Query.by_account_id(account.id)
    |> Emisar.Audit.Event.Query.by_event_type("user.signed_in")
    |> Repo.aggregate(:count)
  end

  defp unboxed_step_up(fun) do
    unboxed_sso(fn context ->
      sibling = Fixtures.Accounts.create_account()
      owner = Fixtures.Users.create_user()

      try do
        sibling_member =
          Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: context.user.id)

        origin_member = Fixtures.Memberships.fetch_membership(context.account.id, context.user.id)
        origin_owner = Fixtures.Subjects.subject_for(owner, context.account)
        sibling_owner = Fixtures.Subjects.subject_for(owner, sibling)
        raw = Fixtures.Auth.create_session_token!(context.user, :magic_link, nil)
        {:ok, _, donor} = Auth.fetch_user_and_token_by_session_token(raw)

        donor_subject =
          Fixtures.Subjects.subject_for(context.user, context.account, session: donor)

        configure_step_up_worker(self())

        assert {:ok, stash} =
                 SSO.begin_session_step_up(
                   context.provider.id,
                   "https://emisar.test/sign_in/sso/callback",
                   Crypto.hash(raw),
                   donor_subject
                 )

        fun.(
          Map.merge(context, %{
            sibling: sibling,
            origin_member: origin_member,
            sibling_member: sibling_member,
            origin_owner: origin_owner,
            sibling_owner: sibling_owner,
            raw: raw,
            donor_subject: donor_subject,
            stash: Map.put(stash, :redirect_uri, "https://emisar.test/sign_in/sso/callback"),
            routes: Auth.MemberGrantRoute.Query.by_token_id(donor.id) |> Repo.all(),
            session_count: target_session_count(context.user)
          })
        )
      after
        Repo.delete_all(from(stored in Account, where: stored.id == ^sibling.id))
        Repo.delete_all(from(stored in User, where: stored.id == ^owner.id))
      end
    end)
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
                user_identity_id: context.identity.id,
                provider_identifier: context.identity.provider_identifier
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
              user_identity_id: context.identity.id,
              provider_identifier: context.identity.provider_identifier
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
            assert {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(token)

            assert Accounts.fetch_membership_by_account_id_or_slug(
                     context.user,
                     context.account.id,
                     session
                   ) ==
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

  test "a real membership activation fences a stale callback before its final session mint" do
    unboxed_sso(fn context ->
      identity =
        context.identity
        |> Ecto.Changeset.change(created_by: :admin)
        |> Repo.update!()

      old_session =
        Fixtures.Auth.create_session_token!(context.user, :sso, nil, %{},
          user_identity_id: identity.id
        )

      expected_topic = Auth.live_socket_topic_for_session(old_session)
      parent = self()
      token_blocker = session_route_blocker(old_session, parent)

      try do
        assert_receive {:session_route_locked, token_backend}, 5_000
        {other_owner, other_account, other_subject} = Fixtures.Subjects.owner_subject()

        try do
          {:ok, %{membership: invitation, invitation_token: invitation_token}} =
            Accounts.invite_user_to_account(
              Fixtures.Accounts.invitation_attrs(
                email: context.user.email,
                role: "operator"
              ),
              other_subject
            )

          activation =
            unboxed_task(fn ->
              Config.put_override(
                :emisar,
                :session_disconnect_handler,
                {:emisar, RecordingSessionDisconnector}
              )

              Config.put_override(:emisar, :retirement_disconnect_test_pid, parent)
              send(parent, {:activation_backend, backend_pid()})

              Accounts.mark_invitation_accepted(
                invitation,
                invitation_token,
                context.user
              )
            end)

          try do
            assert_receive {:activation_backend, activation_backend}, 5_000
            await_blocked_by(activation_backend, token_backend)

            minter =
              unboxed_task(fn ->
                send(parent, {:retirement_minter_backend, backend_pid()})

                Auth.complete_sso_account_sign_in(
                  context.user,
                  context.account.id,
                  %RequestContext{},
                  user_identity_id: identity.id,
                  provider_identifier: identity.provider_identifier
                )
              end)

            try do
              assert_receive {:retirement_minter_backend, minter_backend}, 5_000
              await_blocked_by(minter_backend, activation_backend)

              send(token_blocker.pid, :release)
              assert {:ok, :ok} = Task.await(token_blocker, 30_000)
              assert {:ok, %Membership{}} = Task.await(activation, 30_000)
              assert Task.await(minter, 30_000) == {:error, :provider_disabled}

              assert_receive {:retirement_disconnect, [^expected_topic], false}, 5_000
              assert Repo.reload!(identity).deleted_at

              assert {:ok, _user, session} =
                       Auth.fetch_user_and_token_by_session_token(old_session)

              assert Accounts.fetch_membership_by_account_id_or_slug(
                       context.user,
                       context.account.id,
                       session
                     ) == {:error, :not_found}
            after
              stop_tasks([minter])
            end
          after
            stop_tasks([activation])
          end
        after
          Repo.delete_all(from(stored in Account, where: stored.id == ^other_account.id))
          Repo.delete_all(from(stored in User, where: stored.id == ^other_owner.id))
        end
      after
        send(token_blocker.pid, :release)
        stop_tasks([token_blocker])
      end
    end)
  end

  test "invitation activation and SSO sign-in keep the user before the identity lock" do
    unboxed_sso(fn context ->
      identity =
        context.identity
        |> Ecto.Changeset.change(created_by: :admin)
        |> Repo.update!()

      {other_owner, other_account, other_subject} = Fixtures.Subjects.owner_subject()

      try do
        {:ok, %{membership: invitation, invitation_token: invitation_token}} =
          Accounts.invite_user_to_account(
            Fixtures.Accounts.invitation_attrs(
              email: context.user.email,
              role: "operator"
            ),
            other_subject
          )

        parent = self()
        membership_blocker = membership_blocker(invitation, parent)

        try do
          assert_receive {:membership_locked, membership_backend}, 5_000

          activation =
            unboxed_task(fn ->
              send(parent, {:ordered_activation_backend, backend_pid()})

              Accounts.mark_invitation_accepted(
                invitation,
                invitation_token,
                context.user
              )
            end)

          try do
            assert_receive {:ordered_activation_backend, activation_backend}, 5_000
            await_blocked_by(activation_backend, membership_backend)

            minter =
              unboxed_task(fn ->
                send(parent, {:ordered_minter_backend, backend_pid()})

                Auth.complete_sso_account_sign_in(
                  context.user,
                  context.account.id,
                  %RequestContext{},
                  user_identity_id: identity.id,
                  provider_identifier: identity.provider_identifier
                )
              end)

            try do
              assert_receive {:ordered_minter_backend, minter_backend}, 5_000
              await_blocked_by(minter_backend, activation_backend)

              identity_blocker = identity_blocker(identity, parent)

              try do
                assert_receive {:identity_locked, identity_backend}, 5_000

                send(membership_blocker.pid, :release)
                assert {:ok, %Membership{}} = Task.await(membership_blocker, 30_000)
                await_blocked_by(activation_backend, identity_backend)

                send(identity_blocker.pid, :release)
                assert {:ok, %UserIdentity{}} = Task.await(identity_blocker, 30_000)
                assert {:ok, %Membership{}} = Task.await(activation, 30_000)
                assert Task.await(minter, 30_000) == {:error, :provider_disabled}
                assert Repo.reload!(identity).deleted_at
              after
                send(identity_blocker.pid, :release)
                stop_tasks([identity_blocker])
              end
            after
              stop_tasks([minter])
            end
          after
            stop_tasks([activation])
          end
        after
          send(membership_blocker.pid, :release)
          stop_tasks([membership_blocker])
        end
      after
        Repo.delete_all(from(stored in Account, where: stored.id == ^other_account.id))
        Repo.delete_all(from(stored in User, where: stored.id == ^other_owner.id))
      end
    end)
  end

  test "invitation activation and a synthesized callback keep the user before the identity" do
    unboxed_sso(fn context ->
      identity =
        context.identity
        |> Ecto.Changeset.change(
          created_by: :admin,
          provisioned_via: :scim,
          scim_external_id: context.identity.provider_identifier
        )
        |> Repo.update!()

      claims = %{
        "sub" => identity.provider_identifier,
        "email" => context.user.email,
        "email_verified" => true
      }

      {other_owner, other_account, other_subject} = Fixtures.Subjects.owner_subject()

      try do
        {:ok, %{membership: invitation, invitation_token: invitation_token}} =
          Accounts.invite_user_to_account(
            Fixtures.Accounts.invitation_attrs(
              email: context.user.email,
              role: "operator"
            ),
            other_subject
          )

        parent = self()
        membership_blocker = membership_blocker(invitation, parent)
        identity_blocker = identity_blocker(identity, parent)

        try do
          assert_receive {:membership_locked, membership_backend}, 5_000
          assert_receive {:identity_locked, identity_backend}, 5_000

          activation =
            unboxed_task(fn ->
              send(parent, {:callback_order_activation_backend, backend_pid()})

              Accounts.mark_invitation_accepted(
                invitation,
                invitation_token,
                context.user
              )
            end)

          try do
            assert_receive {:callback_order_activation_backend, activation_backend}, 5_000
            await_blocked_by(activation_backend, membership_backend)

            callback =
              unboxed_task(fn ->
                Config.put_override(:emisar, :sso_oidc_impl, StubOIDC)
                send(parent, {:ordered_callback_backend, backend_pid()})
                SSO.complete_auth(context.provider, %{"_claims" => claims}, %{})
              end)

            try do
              assert_receive {:ordered_callback_backend, callback_backend}, 5_000
              await_blocked_by(callback_backend, activation_backend)

              send(membership_blocker.pid, :release)
              assert {:ok, %Membership{}} = Task.await(membership_blocker, 30_000)
              await_blocked_by(activation_backend, identity_backend)

              send(identity_blocker.pid, :release)
              assert {:ok, %UserIdentity{}} = Task.await(identity_blocker, 30_000)
              assert {:ok, %Membership{}} = Task.await(activation, 30_000)
              assert {:pending, %LinkRequest{}} = Task.await(callback, 30_000)
              assert Repo.reload!(identity).provider_identifier_retired_at
            after
              stop_tasks([callback])
            end
          after
            stop_tasks([activation])
          end
        after
          send(membership_blocker.pid, :release)
          send(identity_blocker.pid, :release)
          stop_tasks([membership_blocker, identity_blocker])
        end
      after
        Repo.delete_all(from(stored in Account, where: stored.id == ^other_account.id))
        Repo.delete_all(from(stored in User, where: stored.id == ^other_owner.id))
      end
    end)
  end

  test "a session minted before membership activation commits is swept after it" do
    unboxed_sso(fn context ->
      identity =
        context.identity
        |> Ecto.Changeset.change(created_by: :admin)
        |> Repo.update!()

      {other_owner, other_account, other_subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{membership: invitation, invitation_token: invitation_token}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(
            email: context.user.email,
            role: "operator"
          ),
          other_subject
        )

      parent = self()
      user_blocker = user_no_key_update_blocker(context.user, parent)

      try do
        assert_receive {:user_no_key_update_locked, user_backend}, 5_000

        try do
          minter =
            unboxed_task(fn ->
              send(parent, {:mint_first_backend, backend_pid()})

              Auth.complete_sso_account_sign_in(
                context.user,
                context.account.id,
                %RequestContext{},
                user_identity_id: identity.id,
                provider_identifier: identity.provider_identifier
              )
            end)

          try do
            assert_receive {:mint_first_backend, minter_backend}, 5_000
            await_blocked_by(minter_backend, user_backend)

            activation =
              unboxed_task(fn ->
                Config.put_override(
                  :emisar,
                  :session_disconnect_handler,
                  {:emisar, RecordingSessionDisconnector}
                )

                Config.put_override(:emisar, :retirement_disconnect_test_pid, parent)
                send(parent, {:mint_first_activation_backend, backend_pid()})

                Accounts.mark_invitation_accepted(
                  invitation,
                  invitation_token,
                  context.user
                )
              end)

            try do
              assert_receive {:mint_first_activation_backend, activation_backend}, 5_000
              await_blocked_by(activation_backend, minter_backend)

              send(user_blocker.pid, :release)
              assert {:ok, :ok} = Task.await(user_blocker, 30_000)
              assert {:ok, minted_session, _mfa?} = Task.await(minter, 30_000)
              expected_topic = Auth.live_socket_topic_for_session(minted_session)

              assert {:ok, %Membership{}} = Task.await(activation, 30_000)
              assert_receive {:retirement_disconnect, [^expected_topic], false}, 5_000
              assert Repo.reload!(identity).deleted_at

              assert {:ok, _user, session} =
                       Auth.fetch_user_and_token_by_session_token(minted_session)

              assert Accounts.fetch_membership_by_account_id_or_slug(
                       context.user,
                       context.account.id,
                       session
                     ) ==
                       {:error, :not_found}
            after
              stop_tasks([activation])
            end
          after
            stop_tasks([minter])
          end
        after
          Repo.delete_all(from(stored in Account, where: stored.id == ^other_account.id))
          Repo.delete_all(from(stored in User, where: stored.id == ^other_owner.id))
        end
      after
        send(user_blocker.pid, :release)
        stop_tasks([user_blocker])
      end
    end)
  end

  test "an approval that commits first is retired by the waiting membership activation" do
    unboxed_sso(fn context ->
      request = matched_link_request(context, "approval-first")
      parent = self()
      identity_blocker = identity_blocker(context.identity, parent)

      try do
        assert_receive {:identity_locked, identity_backend}, 5_000
        {other_owner, other_account, other_subject} = Fixtures.Subjects.owner_subject()

        try do
          {:ok, %{membership: invitation, invitation_token: invitation_token}} =
            Accounts.invite_user_to_account(
              Fixtures.Accounts.invitation_attrs(
                email: context.user.email,
                role: "operator"
              ),
              other_subject
            )

          approval =
            unboxed_task(fn ->
              send(parent, {:approval_first_backend, backend_pid()})

              SSO.approve_link_request(request, Accounts.RunnerAccess.none(), context.subject)
            end)

          try do
            assert_receive {:approval_first_backend, approval_backend}, 5_000
            await_blocked_by(approval_backend, identity_backend)

            activation =
              unboxed_task(fn ->
                send(parent, {:approval_first_activation_backend, backend_pid()})

                Accounts.mark_invitation_accepted(
                  invitation,
                  invitation_token,
                  context.user
                )
              end)

            try do
              assert_receive {:approval_first_activation_backend, activation_backend}, 5_000
              await_blocked_by(activation_backend, approval_backend)

              send(identity_blocker.pid, :release)
              assert {:ok, %UserIdentity{}} = Task.await(identity_blocker, 30_000)
              assert {:ok, %{identity: rebound}} = Task.await(approval, 30_000)
              assert {:ok, %Membership{}} = Task.await(activation, 30_000)
              assert Repo.reload!(rebound).deleted_at
            after
              stop_tasks([activation])
            end
          after
            stop_tasks([approval])
          end
        after
          Repo.delete_all(from(stored in Account, where: stored.id == ^other_account.id))
          Repo.delete_all(from(stored in User, where: stored.id == ^other_owner.id))
        end
      after
        send(identity_blocker.pid, :release)
        stop_tasks([identity_blocker])
      end
    end)
  end

  test "a membership activation that commits first defeats the waiting link approval" do
    unboxed_sso(fn context ->
      identity =
        context.identity
        |> Ecto.Changeset.change(created_by: :admin)
        |> Repo.update!()

      old_session =
        Fixtures.Auth.create_session_token!(context.user, :sso, nil, %{},
          user_identity_id: identity.id
        )

      request = matched_link_request(context, "activation-first")
      parent = self()
      token_blocker = session_route_blocker(old_session, parent)

      try do
        assert_receive {:session_route_locked, token_backend}, 5_000
        {other_owner, other_account, other_subject} = Fixtures.Subjects.owner_subject()

        try do
          {:ok, %{membership: invitation, invitation_token: invitation_token}} =
            Accounts.invite_user_to_account(
              Fixtures.Accounts.invitation_attrs(
                email: context.user.email,
                role: "operator"
              ),
              other_subject
            )

          activation =
            unboxed_task(fn ->
              send(parent, {:activation_first_backend, backend_pid()})

              Accounts.mark_invitation_accepted(
                invitation,
                invitation_token,
                context.user
              )
            end)

          try do
            assert_receive {:activation_first_backend, activation_backend}, 5_000
            await_blocked_by(activation_backend, token_backend)

            approval =
              unboxed_task(fn ->
                send(parent, {:activation_first_approval_backend, backend_pid()})

                SSO.approve_link_request(request, Accounts.RunnerAccess.none(), context.subject)
              end)

            try do
              assert_receive {:activation_first_approval_backend, approval_backend}, 5_000
              await_blocked_by(approval_backend, activation_backend)

              send(token_blocker.pid, :release)
              assert {:ok, :ok} = Task.await(token_blocker, 30_000)
              assert {:ok, %Membership{}} = Task.await(activation, 30_000)

              assert Task.await(approval, 30_000) ==
                       {:error, :link_target_in_other_accounts}

              assert Repo.reload!(identity).deleted_at
              assert Repo.reload!(request)

              assert {:ok, _user, session} =
                       Auth.fetch_user_and_token_by_session_token(old_session)

              assert Accounts.fetch_membership_by_account_id_or_slug(
                       context.user,
                       context.account.id,
                       session
                     ) == {:error, :not_found}
            after
              stop_tasks([approval])
            end
          after
            stop_tasks([activation])
          end
        after
          Repo.delete_all(from(stored in Account, where: stored.id == ^other_account.id))
          Repo.delete_all(from(stored in User, where: stored.id == ^other_owner.id))
        end
      after
        send(token_blocker.pid, :release)
        stop_tasks([token_blocker])
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

            SSO.approve_link_request(request, Accounts.RunnerAccess.none(), context.subject)
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

  test "a matched approval takes the account lock before the provider lock" do
    unboxed_sso(fn context ->
      request =
        Fixtures.SSO.create_link_request(
          provider: context.provider,
          provider_identifier: "matched-order-#{Ecto.UUID.generate()}",
          source: :oidc,
          namespace_fingerprint: SSO.Provisioning.namespace_fingerprint(context.provider),
          email: context.user.email,
          claims: %{
            "sub" => "matched-order-subject",
            "email" => context.user.email,
            "email_verified" => true
          },
          matched_user_id: context.user.id
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

  for mode <- [:opposite_sso_origins, :personal_and_partial_sso] do
    @mode mode
    test "#{mode} minting serializes before User without blocking audit foreign keys" do
      unboxed_sso(fn context ->
        sibling = Fixtures.Accounts.create_account(plan: "enterprise")

        try do
          Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: context.user.id)

          issuer =
            if @mode == :opposite_sso_origins,
              do: context.provider.issuer,
              else: "https://different-#{sibling.id}.test"

          provider =
            Fixtures.SSO.create_identity_provider(
              account_id: sibling.id,
              issuer: issuer,
              client_id: "sibling-client"
            )

          identity =
            Fixtures.SSO.create_user_identity(
              account_id: sibling.id,
              provider_id: provider.id,
              user_id: context.user.id,
              provider_identifier: "sibling-person"
            )

          assert context.account.id < sibling.id

          {first_identity, second_mint} =
            case @mode do
              :opposite_sso_origins ->
                {context.identity, fn -> mint_sso(context.user, identity) end}

              :personal_and_partial_sso ->
                {:ok, %{token_id: factor_id, nonce: nonce}} =
                  Auth.request_magic_link(context.user, %RequestContext{})

                assert_receive {:email, email}

                {:ok, _user} =
                  Auth.verify_magic_link(factor_id, Fixtures.Auth.code_from_email(email), nonce)

                {identity,
                 fn ->
                   assert {:ok, _user, raw, :no_target, false} =
                            Auth.complete_magic_link_sign_in(
                              context.user.id,
                              factor_id,
                              nil,
                              %RequestContext{}
                            )

                   {:ok, raw, false}
                 end}
            end

          parent = self()
          blocker = user_no_key_update_blocker(context.user, parent)

          try do
            assert_receive {:user_no_key_update_locked, blocker_backend}, 5_000

            first =
              unboxed_task(fn ->
                send(parent, {:first_mint_backend, backend_pid()})
                mint_sso(context.user, first_identity)
              end)

            try do
              assert_receive {:first_mint_backend, first_backend}, 5_000
              await_blocked_by(first_backend, blocker_backend)

              second =
                unboxed_task(fn ->
                  send(parent, {:second_mint_backend, backend_pid()})
                  second_mint.()
                end)

              try do
                assert_receive {:second_mint_backend, second_backend}, 5_000
                await_blocked_by(second_backend, first_backend)
                send(blocker.pid, :release)
                assert {:ok, :ok} = Task.await(blocker, 30_000)
                assert {:ok, first_raw, _mfa} = Task.await(first, 30_000)
                assert {:ok, second_raw, _mfa} = Task.await(second, 30_000)

                for {raw, origin} <- [
                      {first_raw, first_identity.account_id},
                      {second_raw, sibling.id}
                    ] do
                  assert {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(raw)
                  routes = Auth.MemberGrantRoute.Query.by_token_id(session.id) |> Repo.all()

                  expected =
                    if @mode == :personal_and_partial_sso and raw == first_raw,
                      do: [sibling.id],
                      else: [context.account.id, sibling.id]

                  assert Enum.sort(Enum.map(routes, & &1.account_id)) == Enum.sort(expected)

                  if session.auth_method == :sso do
                    assert Enum.all?(routes, &(&1.direct == (&1.account_id == origin)))
                  else
                    assert Enum.all?(routes, &(&1.auth_method == :magic_link))
                  end
                end

                events =
                  Emisar.Audit.Event.Query.all()
                  |> Emisar.Audit.Event.Query.by_account_id(sibling.id)
                  |> Emisar.Audit.Event.Query.by_event_type("user.signed_in")
                  |> Repo.all()

                assert length(events) == 2
              after
                stop_tasks([second])
              end
            after
              stop_tasks([first])
            end
          after
            send(blocker.pid, :release)
            stop_tasks([blocker])
          end
        after
          Repo.delete_all(from(stored in Account, where: stored.id == ^sibling.id))
        end
      end)
    end
  end

  defp mint_sso(user, identity) do
    Auth.complete_sso_account_sign_in(user, identity.account_id, %RequestContext{},
      user_identity_id: identity.id,
      provider_identifier: identity.provider_identifier
    )
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

  defp session_grant_blocker(raw_token, parent) do
    {:ok, _user, token} = Auth.fetch_user_and_token_by_session_token(raw_token)

    unboxed_task(fn ->
      Repo.transaction(fn ->
        Auth.MemberGrant.Query.by_token_id(token.id)
        |> Auth.MemberGrant.Query.lock_for_update()
        |> Repo.all()

        send(parent, {:session_grants_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  defp session_route_blocker(raw_token, parent) do
    {:ok, _user, token} = Auth.fetch_user_and_token_by_session_token(raw_token)

    unboxed_task(fn ->
      Repo.transaction(fn ->
        Auth.MemberGrantRoute.Query.by_token_id(token.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

        send(parent, {:session_route_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  defp membership_blocker(membership, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        locked =
          Membership.Query.not_deleted()
          |> Membership.Query.by_id(membership.id)
          |> Membership.Query.lock_for_update()
          |> Repo.fetch!(Membership.Query)

        send(parent, {:membership_locked, backend_pid()})

        receive do
          :release -> locked
        end
      end)
    end)
  end

  defp identity_blocker(identity, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        UserIdentity.Query.not_deleted()
        |> UserIdentity.Query.by_id(identity.id)
        |> UserIdentity.Query.lock_for_update()
        |> Repo.fetch!(UserIdentity.Query)

        send(parent, {:identity_locked, backend_pid()})

        receive do
          :release -> identity
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

  defp user_no_key_update_blocker(user, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        User.Query.not_deleted()
        |> User.Query.by_id(user.id)
        |> lock("FOR NO KEY UPDATE")
        |> Repo.fetch!(User.Query)

        send(parent, {:user_no_key_update_locked, backend_pid()})

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

  defp matched_link_request(context, suffix) do
    identifier = "#{suffix}-#{Ecto.UUID.generate()}"

    Fixtures.SSO.create_link_request(
      provider: context.provider,
      provider_identifier: identifier,
      source: :oidc,
      namespace_fingerprint: SSO.Provisioning.namespace_fingerprint(context.provider),
      email: context.user.email,
      claims: %{
        "sub" => identifier,
        "email" => context.user.email,
        "email_verified" => true
      },
      matched_user_id: context.user.id
    )
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
end
