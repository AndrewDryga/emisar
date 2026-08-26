defmodule Emisar.AuthEmailAddressConcurrencyTest do
  use ExUnit.Case, async: false
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

      assert Auth.issue_email_change_code(new_email, subject) == :ok
      assert_received {:email, step_up_email}
      step_up_code = Fixtures.Auth.code_from_email(step_up_email)

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
            result = Auth.confirm_email_change(new_email, step_up_code, subject)
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

              assert {{:ok, %User{email: ^new_email}}, [email_change_confirmation]} =
                       Task.await(changer, 30_000)

              assert {{:error, :not_found}, []} = Task.await(stale_magic_issuer, 30_000)

              assert {:ok, [stale_issuer_confirmation]} =
                       Task.await(stale_confirmation_issuer, 30_000)

              assert Repo.reload!(user).email == new_email

              assert Auth.verify_magic_link(magic_id, magic_secret, nonce) ==
                       {:error, :invalid_or_expired}

              assert Auth.confirm_user_by_token(old_confirmation) ==
                       {:error, :invalid_or_expired}

              confirmation_emails = [email_change_confirmation, stale_issuer_confirmation]

              assert Enum.all?(confirmation_emails, &(&1.to == [{"", new_email}]))

              refute_received {:email, %{to: [{"", ^old_email}]}}

              assert [%UserToken{context: "confirm", sent_to: ^new_email}] =
                       UserToken.Query.by_user_id(user.id) |> Repo.all()

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
      step_up_code = issue_email_change_code(new_email, subject)
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
            {Auth.confirm_email_change(new_email, step_up_code, subject), drain_emails()}
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

            assert {{:ok, %User{email: ^new_email}}, [confirmation]} =
                     Task.await(changer, 30_000)

            assert confirmation.to == [{"", new_email}]

            assert Task.await(minter, 30_000) ==
                     {:error, :invalid_or_expired}

            refute Repo.get(UserToken, factor_id)

            refute UserToken.Query.by_user_id(user.id)
                   |> UserToken.Query.by_context("session")
                   |> Repo.exists?()

            assert [%UserToken{context: "confirm", sent_to: ^new_email}] =
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
      step_up_code = issue_email_change_code(new_email, subject)
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
              {Auth.confirm_email_change(new_email, step_up_code, subject), drain_emails()}
            end)

          try do
            assert_receive {:mint_first_changer_backend, changer_backend}, 5_000
            await_blocked_by(changer_backend, minter_backend)

            send(factor_blocker.pid, :release)
            assert {:ok, :ok} = Task.await(factor_blocker, 30_000)

            assert {:ok, %User{id: user_id}, raw_session, :no_target, false} =
                     Task.await(minter, 30_000)

            assert user_id == user.id

            assert {{:ok, %User{email: ^new_email}}, [confirmation]} =
                     Task.await(changer, 30_000)

            assert confirmation.to == [{"", new_email}]

            assert {:ok, %User{id: ^user_id}, %UserToken{context: "session"}} =
                     Auth.fetch_user_and_token_by_session_token(raw_session)

            refute Repo.get(UserToken, factor_id)

            assert 1 ==
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

  test "email-change-first makes a fresh invitation resolve the address's new owner" do
    unboxed_owner(fn owner, account, subject ->
      original_email = "invite-race-#{Ecto.UUID.generate()}@example.test"
      moved_email = "moved-invite-#{Ecto.UUID.generate()}@example.test"
      target = Fixtures.Users.create_user(%{email: original_email})
      parent = self()

      changer =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            loaded =
              Emisar.Users.User.Query.not_deleted()
              |> Emisar.Users.User.Query.by_id(target.id)
              |> Emisar.Users.User.Query.lock_for_update()
              |> Repo.one!()

            updated =
              loaded
              |> User.Changeset.email(%{email: moved_email})
              |> Repo.update!()

            send(parent, {:invited_user_email_changed, backend_pid()})

            receive do
              :release -> updated
            end
          end)
        end)

      try do
        assert_receive {:invited_user_email_changed, changer_backend}, 5_000

        inviter =
          unboxed_task(fn ->
            send(parent, {:inviter_backend, backend_pid()})

            result =
              Accounts.invite_user_to_account_and_deliver(
                Fixtures.Accounts.invitation_attrs(
                  email: original_email,
                  role: "operator",
                  runner_access_mode: "all"
                ),
                owner,
                subject
              )

            {result, drain_emails()}
          end)

        try do
          assert_receive {:inviter_backend, inviter_backend}, 5_000
          await_blocked_by(inviter_backend, changer_backend)

          send(changer.pid, :release)
          assert {:ok, %User{email: ^moved_email}} = Task.await(changer, 30_000)

          assert {{:ok, %{user: invited, membership: membership}}, [email]} =
                   Task.await(inviter, 30_000)

          refute invited.id == target.id
          assert invited.email == original_email
          assert membership.user_id == invited.id
          assert membership.invitation_sent_to == original_email
          assert membership.invitation_email_changed_at == invited.email_changed_at
          assert email.to == [{"", original_email}]

          refute Accounts.Membership.Query.not_deleted()
                 |> Accounts.Membership.Query.by_user_id(target.id)
                 |> Repo.exists?()
        after
          stop_tasks([inviter])
        end
      after
        send(changer.pid, :release)
        stop_tasks([changer])

        Repo.delete_all(from(account_row in Account, where: account_row.id == ^account.id))

        Repo.delete_all(from(user in User, where: user.email in ^[original_email, moved_email]))
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

  defp issue_email_change_code(new_email, subject) do
    assert Auth.issue_email_change_code(new_email, subject) == :ok
    assert_receive {:email, email}, 5_000
    Fixtures.Auth.code_from_email(email)
  end

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

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      try do
        fun.(user, account, subject)
      after
        Repo.delete_all(from(account in Account, where: account.id == ^account.id))
        Repo.delete_all(from(user in User, where: user.id == ^user.id))
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
