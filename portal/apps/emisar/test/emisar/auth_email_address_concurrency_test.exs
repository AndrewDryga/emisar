defmodule Emisar.AuthEmailAddressConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Auth, Fixtures, Repo, RequestContext}
  alias Emisar.Accounts.Account
  alias Emisar.Auth.UserToken
  alias Emisar.Users.User

  @moduletag timeout: 60_000

  test "a committed email change defeats stale issuance and leaves only new-address credentials" do
    unboxed_owner(fn user, account, subject ->
      old_email = user.email
      new_email = "changed-#{Ecto.UUID.generate()}@example.test"
      context = %RequestContext{}

      assert {:ok, %{token_id: magic_id, nonce: nonce}} =
               Auth.request_magic_link(user, context)

      assert_received {:email, magic_email}

      [_, ^magic_id, magic_secret] =
        Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", magic_email.text_body)

      old_confirmation = Fixtures.Auth.create_confirmation_token!(user)

      proof = pending_email_change(new_email, subject)

      parent = self()

      token_blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            from(token in UserToken,
              where: token.id == ^magic_id,
              lock: "FOR UPDATE"
            )
            |> Repo.one!()

            send(parent, {:token_locked, backend_pid()})

            receive do
              :release -> :ok
            end
          end)
        end)

      try do
        assert_receive {:token_locked, blocker_backend}, 5_000

        changer =
          unboxed_task(fn ->
            send(parent, {:changer_backend, backend_pid()})
            result = complete_email_change(proof, subject)
            {result, drain_emails()}
          end)

        try do
          assert_receive {:changer_backend, changer_backend}, 5_000
          await_blocked_by(changer_backend, blocker_backend)

          stale_magic_issuer =
            unboxed_task(fn ->
              send(parent, {:magic_issuer_backend, backend_pid()})
              result = Auth.request_magic_link(user, context)
              {result, drain_emails()}
            end)

          try do
            assert_receive {:magic_issuer_backend, magic_issuer_backend}, 5_000
            await_blocked_by(magic_issuer_backend, changer_backend)

            stale_confirmation_issuer =
              unboxed_task(fn ->
                send(parent, {:confirmation_issuer_backend, backend_pid()})
                result = Auth.deliver_confirmation_instructions(user)
                {result, drain_emails()}
              end)

            try do
              assert_receive {:confirmation_issuer_backend, confirmation_issuer_backend}, 5_000
              await_blocked_by(confirmation_issuer_backend, magic_issuer_backend)

              send(token_blocker.pid, :release)
              assert {:ok, :ok} = Task.await(token_blocker, 30_000)

              assert {{:ok, %User{email: ^new_email, confirmed_at: %DateTime{}}}, []} =
                       Task.await(changer, 30_000)

              assert {{:error, :not_found}, []} = Task.await(stale_magic_issuer, 30_000)

              assert {:ok, [stale_issuer_confirmation]} =
                       Task.await(stale_confirmation_issuer, 30_000)

              assert Repo.reload!(user).email == new_email

              assert Auth.verify_magic_link(magic_id, magic_secret, nonce) ==
                       {:error, :invalid_or_expired}

              assert Auth.confirm_user_by_token(old_confirmation) ==
                       {:error, :invalid_or_expired}

              assert stale_issuer_confirmation.to == [{"", new_email}]

              refute_received {:email, %{to: [{"", ^old_email}]}}

              assert [%UserToken{context: "confirm", sent_to: ^new_email}] =
                       UserToken.Query.by_user_id(user.id)
                       |> UserToken.Query.by_context("confirm")
                       |> Repo.all()

              assert Enum.sort(
                       Enum.map(UserToken.Query.by_user_id(user.id) |> Repo.all(), & &1.context)
                     ) ==
                       ["confirm", "session"]

              assert 1 ==
                       Emisar.Audit.Event.Query.all()
                       |> Emisar.Audit.Event.Query.by_account_id(account.id)
                       |> Emisar.Audit.Event.Query.by_event_type("user.magic_link_issued")
                       |> Repo.aggregate(:count)
            after
              stop_tasks([stale_confirmation_issuer])
            end
          after
            stop_tasks([stale_magic_issuer])
          end
        after
          stop_tasks([changer])
        end
      after
        send(token_blocker.pid, :release)
        stop_tasks([token_blocker])
      end
    end)
  end

  test "email-change-first deletes the verified factor before final session mint" do
    unboxed_owner(fn user, _account, subject ->
      new_email = "change-first-#{Ecto.UUID.generate()}@example.test"
      factor_id = verify_magic_factor(user)
      proof = pending_email_change(new_email, subject)
      parent = self()

      factor_blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            from(token in UserToken,
              where: token.id == ^factor_id,
              lock: "FOR UPDATE"
            )
            |> Repo.one!()

            send(parent, {:factor_locked, backend_pid()})

            receive do
              :release -> :ok
            end
          end)
        end)

      try do
        assert_receive {:factor_locked, blocker_backend}, 5_000

        changer =
          unboxed_task(fn ->
            send(parent, {:change_first_backend, backend_pid()})
            {complete_email_change(proof, subject), drain_emails()}
          end)

        try do
          assert_receive {:change_first_backend, changer_backend}, 5_000
          await_blocked_by(changer_backend, blocker_backend)

          minter =
            unboxed_task(fn ->
              send(parent, {:change_first_minter_backend, backend_pid()})

              Auth.complete_magic_link_sign_in(
                user.id,
                factor_id,
                nil,
                %RequestContext{}
              )
            end)

          try do
            assert_receive {:change_first_minter_backend, minter_backend}, 5_000
            await_blocked_by(minter_backend, changer_backend)

            send(factor_blocker.pid, :release)
            assert {:ok, :ok} = Task.await(factor_blocker, 30_000)

            assert {{:ok, %User{email: ^new_email, confirmed_at: %DateTime{}}}, []} =
                     Task.await(changer, 30_000)

            assert Task.await(minter, 30_000) ==
                     {:error, :invalid_or_expired}

            refute Repo.get(UserToken, factor_id)

            # Only the already-authorizing session survives; the waiting mint
            # never acquires an additional session from the old-address factor.
            assert [%UserToken{context: "session"}] =
                     UserToken.Query.by_user_id(user.id) |> Repo.all()
          after
            stop_tasks([minter])
          end
        after
          stop_tasks([changer])
        end
      after
        send(factor_blocker.pid, :release)
        stop_tasks([factor_blocker])
      end
    end)
  end

  test "session-mint-first linearizes before the address change" do
    unboxed_owner(fn user, _account, subject ->
      new_email = "mint-first-#{Ecto.UUID.generate()}@example.test"
      factor_id = verify_magic_factor(user)
      proof = pending_email_change(new_email, subject)
      parent = self()

      factor_blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            from(token in UserToken,
              where: token.id == ^factor_id,
              lock: "FOR UPDATE"
            )
            |> Repo.one!()

            send(parent, {:mint_factor_locked, backend_pid()})

            receive do
              :release -> :ok
            end
          end)
        end)

      try do
        assert_receive {:mint_factor_locked, blocker_backend}, 5_000

        minter =
          unboxed_task(fn ->
            send(parent, {:mint_first_backend, backend_pid()})

            Auth.complete_magic_link_sign_in(
              user.id,
              factor_id,
              nil,
              %RequestContext{}
            )
          end)

        try do
          assert_receive {:mint_first_backend, minter_backend}, 5_000
          await_blocked_by(minter_backend, blocker_backend)

          changer =
            unboxed_task(fn ->
              send(parent, {:mint_first_changer_backend, backend_pid()})
              {complete_email_change(proof, subject), drain_emails()}
            end)

          try do
            assert_receive {:mint_first_changer_backend, changer_backend}, 5_000
            await_blocked_by(changer_backend, minter_backend)

            send(factor_blocker.pid, :release)
            assert {:ok, :ok} = Task.await(factor_blocker, 30_000)

            assert {:ok, %User{id: user_id}, raw_session, :no_target, false} =
                     Task.await(minter, 30_000)

            assert user_id == user.id

            assert {{:ok, %User{email: ^new_email, confirmed_at: %DateTime{}}}, []} =
                     Task.await(changer, 30_000)

            assert {:ok, %UserToken{user: %User{id: ^user_id}, context: "session"}} =
                     Auth.fetch_session_by_token(raw_session)

            refute Repo.get(UserToken, factor_id)

            assert 2 ==
                     UserToken.Query.by_user_id(user.id)
                     |> UserToken.Query.by_context("session")
                     |> Repo.aggregate(:count, :id)
          after
            stop_tasks([changer])
          end
        after
          stop_tasks([minter])
        end
      after
        send(factor_blocker.pid, :release)
        stop_tasks([factor_blocker])
      end
    end)
  end

  test "the losing concurrent resend fails closed instead of crossing registration intent" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      user = Fixtures.Users.create_user(%{email: "resend-race-#{suffix}@example.test"})
      account_name = "Resend race #{suffix}"
      parent = self()

      assert {:ok, %{token_id: original_id}} =
               Auth.request_magic_link(user, %RequestContext{},
                 owner_registration: %{
                   account_name: account_name,
                   full_name: "Inbox Owner"
                 }
               )

      assert_received {:email, _original_email}

      token_blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            from(token in UserToken,
              where: token.id == ^original_id,
              lock: "FOR UPDATE"
            )
            |> Repo.one!()

            send(parent, {:resend_token_locked, backend_pid()})

            receive do
              :release -> :ok
            end
          end)
        end)

      try do
        assert_receive {:resend_token_locked, blocker_backend}, 5_000

        first_resend =
          unboxed_task(fn ->
            send(parent, {:first_resend_backend, backend_pid()})

            result =
              Auth.request_magic_link(user, %RequestContext{},
                prior_magic_link_token_id: original_id
              )

            {result, drain_emails()}
          end)

        try do
          assert_receive {:first_resend_backend, first_backend}, 5_000
          await_blocked_by(first_backend, blocker_backend)

          second_resend =
            unboxed_task(fn ->
              send(parent, {:second_resend_backend, backend_pid()})

              result =
                Auth.request_magic_link(user, %RequestContext{},
                  prior_magic_link_token_id: original_id
                )

              {result, drain_emails()}
            end)

          try do
            assert_receive {:second_resend_backend, second_backend}, 5_000
            await_blocked_by(second_backend, first_backend)

            send(token_blocker.pid, :release)
            assert {:ok, :ok} = Task.await(token_blocker, 30_000)

            assert {{:ok, %{token_id: first_id}}, [_first_email]} =
                     Task.await(first_resend, 30_000)

            assert {{:ok, %{token_id: second_id, nonce: second_nonce}}, [second_email]} =
                     Task.await(second_resend, 30_000)

            refute first_id == second_id
            refute Repo.get(UserToken, first_id)

            assert %UserToken{id: ^second_id, metadata: %{}} = Repo.get!(UserToken, second_id)

            [_, ^second_id, secret] =
              Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", second_email.text_body)

            assert {:ok, %User{id: user_id}} =
                     Auth.verify_magic_link(second_id, secret, second_nonce)

            assert user_id == user.id

            assert {:ok, _user, _session, :no_target, false} =
                     Auth.complete_magic_link_sign_in(
                       user.id,
                       second_id,
                       nil,
                       %RequestContext{}
                     )

            refute Repo.get_by(Account, name: account_name)

            refute Accounts.Membership.Query.not_deleted()
                   |> Accounts.Membership.Query.by_user_id(user.id)
                   |> Repo.exists?()
          after
            stop_tasks([second_resend])
          end
        after
          stop_tasks([first_resend])
        end
      after
        send(token_blocker.pid, :release)
        stop_tasks([token_blocker])
        Repo.delete_all(from(account_row in Account, where: account_row.name == ^account_name))
        Repo.delete_all(from(user_row in User, where: user_row.id == ^user.id))
      end
    end)
  end

  defp verify_magic_factor(user) do
    assert {:ok, %{token_id: token_id, nonce: nonce}} =
             Auth.request_magic_link(user, %RequestContext{})

    assert_receive {:email, email}, 5_000
    [_, ^token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", email.text_body)
    assert {:ok, %User{id: user_id}} = Auth.verify_magic_link(token_id, secret, nonce)
    assert user_id == user.id
    assert %UserToken{context: "magic_link_verified"} = Repo.get!(UserToken, token_id)
    token_id
  end

  defp pending_email_change(new_email, subject) do
    assert Auth.issue_email_change_code(new_email, subject) == {:ok, :sent}
    assert_receive {:email, email}, 5_000

    {:ok, session} = Auth.fetch_current_session(subject)
    digest = session.token

    assert {:ok, proof} =
             Auth.confirm_email_change(
               new_email,
               Fixtures.Auth.code_from_email(email),
               digest,
               subject
             )

    assert_receive {:email, new_mail}, 5_000
    {proof, Fixtures.Auth.code_from_email(new_mail), digest}
  end

  defp complete_email_change({proof, code, digest}, subject),
    do: Auth.complete_email_change(proof.token_id, proof.nonce, code, digest, subject)

  defp drain_emails(emails \\ []) do
    receive do
      {:email, email} -> drain_emails([email | emails])
    after
      0 -> Enum.reverse(emails)
    end
  end

  defp unboxed_owner(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      user = Fixtures.Users.create_user(%{email: "email-race-#{suffix}@example.test"})

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "Email race #{suffix}", slug: "email-race-#{suffix}"},
          user
        )

      subject =
        Fixtures.Subjects.subject_for(user, account, role: :owner, auth_method: :magic_link)

      try do
        fun.(user, account, subject)
      after
        Repo.delete_all(from(account in Account, where: account.id == ^account.id))
        Repo.delete_all(from(user in User, where: user.id == ^user.id))
      end
    end)
  end
end
