defmodule Emisar.AuthSignUpConcurrencyTest do
  @moduledoc """
  The two sign-up races that must each leave exactly one thing behind: two
  concurrent starts for one address leave one usable code (the advisory lock
  on the normalized address plus the partial unique index), and a double
  submit of one proved code creates one workspace (the code's row lock).
  """
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.Accounts.{Account, Membership}
  alias Emisar.{Auth, Repo, RequestContext}
  alias Emisar.Auth.UserToken

  @context %RequestContext{}

  defp sign_up_attrs(email) do
    %{
      "email" => email,
      "full_name" => "Ada Lovelace",
      "account_name" => "Analytical Engines #{System.unique_integer([:positive])}"
    }
  end

  # The code only leaves Auth by email; the task that requested it holds the
  # delivery, so the requester hands back the whole message.
  defp request_code(attrs) do
    {:ok, %{token_id: token_id, nonce: nonce, delivery: {:ok, :sent}}} =
      Auth.request_sign_up_code(attrs, @context)

    receive do
      {:email, sent} ->
        [_, ^token_id, secret] =
          Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)

        %{token_id: token_id, nonce: nonce, secret: secret}
    after
      1_000 -> raise "sign-up code email was not delivered"
    end
  end

  defp sign_up_codes(email) do
    UserToken.Query.by_context("sign_up")
    |> UserToken.Query.by_sent_to(email)
    |> Repo.all()
  end

  defp cleanup(email) do
    Repo.delete_all(from(t in UserToken, where: fragment("lower(?)", t.sent_to) == ^email))

    account_ids =
      Repo.all(from(m in Membership, where: m.email == ^email, select: m.account_id))

    Repo.delete_all(from(a in Account, where: a.id in ^account_ids))
  end

  test "two concurrent starts for one address leave one usable code" do
    Sandbox.unboxed_run(Repo, fn ->
      email = "race-#{System.unique_integer([:positive])}@example.test"
      attrs = sign_up_attrs(email)
      parent = self()

      # One start holds the address — the lock the issuance takes first.
      holder =
        unboxed_task(fn ->
          Repo.transact(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1 || lower($2), 0))", [
              "emisar.auth.sign_up:",
              email
            ])

            send(parent, {:address_locked, backend_pid()})

            receive do
              :release -> {:ok, :released}
            end
          end)
        end)

      Process.unlink(holder.pid)

      try do
        assert_receive {:address_locked, holder_backend}, 5_000

        # The other start for the same address, spelled differently, queues on it.
        requester =
          unboxed_task(fn ->
            send(parent, {:requester, backend_pid()})
            request_code(%{attrs | "email" => String.upcase(email)})
          end)

        Process.unlink(requester.pid)

        try do
          assert_receive {:requester, requester_backend}, 5_000
          await_blocked_by(requester_backend, holder_backend)
          assert sign_up_codes(email) == []

          send(holder.pid, :release)
          assert {:ok, first} = Task.yield(requester, 5_000)

          # A later start replaces the earlier code: one row, one code that works.
          second = request_code(attrs)

          assert [token] = sign_up_codes(email)
          assert token.id == second.token_id

          assert Auth.verify_magic_link(first.token_id, first.secret, first.nonce) ==
                   {:error, :invalid_or_expired}

          assert Auth.verify_magic_link(second.token_id, second.secret, second.nonce) ==
                   {:ok, nil}
        after
          stop_tasks([requester])
        end
      after
        send(holder.pid, :release)
        Task.yield(holder, 5_000) || Task.shutdown(holder, :brutal_kill)
        cleanup(email)
      end
    end)
  end

  test "a resend that read its code before completion finds it consumed afterwards" do
    Sandbox.unboxed_run(Repo, fn ->
      email = "resend-race-#{System.unique_integer([:positive])}@example.test"
      attrs = sign_up_attrs(email)
      parent = self()

      try do
        code = request_code(attrs)
        assert Auth.verify_magic_link(code.token_id, code.secret, code.nonce) == {:ok, nil}

        # Holding the address parks the resend right after its unlocked read of
        # the code — the lock the reissuance takes first.
        holder =
          unboxed_task(fn ->
            Repo.transact(fn ->
              Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1 || lower($2), 0))", [
                "emisar.auth.sign_up:",
                email
              ])

              send(parent, {:address_locked, backend_pid()})

              receive do
                :release -> {:ok, :released}
              end
            end)
          end)

        Process.unlink(holder.pid)

        try do
          assert_receive {:address_locked, holder_backend}, 5_000

          resender =
            unboxed_task(fn ->
              send(parent, {:resender, backend_pid()})
              Auth.resend_email_code(code.token_id, @context)
            end)

          Process.unlink(resender.pid)

          try do
            assert_receive {:resender, resender_backend}, 5_000
            await_blocked_by(resender_backend, holder_backend)

            # Completion takes no address lock: it consumes the code and creates
            # the workspace while the resend is still waiting.
            assert {:ok, %Membership{} = owner, _raw} =
                     Auth.complete_sign_up(code.token_id, "browser-one", @context)

            send(holder.pid, :release)
            assert {:ok, {:error, :not_found}} = Task.yield(resender, 5_000)

            assert sign_up_codes(email) == []

            assert [%Membership{id: owner_id}] =
                     Repo.all(from(m in Membership, where: m.email == ^email))

            assert owner_id == owner.id

            assert Repo.aggregate(
                     from(a in Account, where: a.id == ^owner.account_id),
                     :count
                   ) == 1
          after
            stop_tasks([resender])
          end
        after
          send(holder.pid, :release)
          Task.yield(holder, 5_000) || Task.shutdown(holder, :brutal_kill)
        end
      after
        cleanup(email)
      end
    end)
  end

  test "a double submit of one proved code creates one workspace" do
    Sandbox.unboxed_run(Repo, fn ->
      email = "double-#{System.unique_integer([:positive])}@example.test"
      attrs = sign_up_attrs(email)
      parent = self()

      try do
        code = request_code(attrs)
        assert Auth.verify_magic_link(code.token_id, code.secret, code.nonce) == {:ok, nil}

        # One submit holds the code's row — the lock completion takes first.
        holder =
          unboxed_task(fn ->
            Repo.transact(fn ->
              UserToken.Query.by_id(code.token_id)
              |> UserToken.Query.lock_for_update()
              |> Repo.one!()

              send(parent, {:code_locked, backend_pid()})

              receive do
                :release -> {:ok, :released}
              end
            end)
          end)

        Process.unlink(holder.pid)

        try do
          assert_receive {:code_locked, holder_backend}, 5_000

          submitter =
            unboxed_task(fn ->
              send(parent, {:submitter, backend_pid()})
              Auth.complete_sign_up(code.token_id, "browser-one", @context)
            end)

          Process.unlink(submitter.pid)

          try do
            assert_receive {:submitter, submitter_backend}, 5_000
            await_blocked_by(submitter_backend, holder_backend)
            send(holder.pid, :release)

            assert {:ok, {:ok, %Membership{} = owner, _raw}} = Task.yield(submitter, 5_000)

            # The second submit waited on the row and then found it consumed.
            assert Auth.complete_sign_up(code.token_id, "browser-two", @context) ==
                     {:error, :invalid_or_expired}

            assert [%Membership{id: owner_id}] =
                     Repo.all(from(m in Membership, where: m.email == ^email))

            assert owner_id == owner.id

            assert Repo.aggregate(
                     from(a in Account, where: a.id == ^owner.account_id),
                     :count
                   ) == 1

            assert sign_up_codes(email) == []
          after
            stop_tasks([submitter])
          end
        after
          send(holder.pid, :release)
          Task.yield(holder, 5_000) || Task.shutdown(holder, :brutal_kill)
        end
      after
        cleanup(email)
      end
    end)
  end
end
