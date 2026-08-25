defmodule Emisar.OAuthRefreshConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Fixtures, OAuth, Repo}
  alias Emisar.Accounts.Account
  alias Emisar.ApiKeys.ApiKey
  alias Emisar.Audit.Event
  alias Emisar.OAuth.{Client, Token}
  alias Emisar.Users.User

  @moduletag timeout: 60_000
  @redirect "https://claude.ai/api/mcp/auth_callback"
  @resource Emisar.PublicUrl.url("/api/mcp/rpc")

  test "simultaneous refresh has one winner and the replaying loser revokes its successor" do
    unboxed_oauth(fn state ->
      parent = self()

      blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Account.Query.active()
            |> Account.Query.by_id(state.account.id)
            |> Account.Query.lock_for_update()
            |> Repo.one!()

            send(parent, {:account_locked, backend_pid()})

            receive do
              :release -> :ok
            end
          end)
        end)

      try do
        assert_receive {:account_locked, blocker_backend}, 5_000

        refreshers = Enum.map(1..2, &start_refresher(state, parent, &1))

        try do
          refresher_backends =
            Enum.map(1..2, fn index ->
              assert_receive {:refresher_started, ^index, backend}, 5_000
              backend
            end)

          Enum.each(refresher_backends, &await_blocked/1)
          assert Enum.any?(refresher_backends, &blocked_by?(&1, blocker_backend))

          send(blocker.pid, :release)
          assert {:ok, :ok} = Task.await(blocker, 30_000)

          results = Enum.map(refreshers, &Task.await(&1, 30_000))
          assert Enum.count(results, &match?({:ok, _tokens}, &1)) == 1
          assert Enum.count(results, &(&1 == {:error, :invalid_grant})) == 1

          {:ok, successor} = Enum.find(results, &match?({:ok, _tokens}, &1))

          assert OAuth.resolve_access_token(successor.access_token, @resource) ==
                   {:error, :invalid}

          assert %ApiKey{revoked_at: %DateTime{}} = Repo.reload!(state.key)

          assert Enum.all?(
                   Repo.all(Token.Query.by_api_key_ids([state.key.id])),
                   &match?(%Token{revoked_at: %DateTime{}}, &1)
                 )

          assert [%Event{payload: %{"client_id" => client_id}}] =
                   Event.Query.all()
                   |> Event.Query.by_account_id(state.account.id)
                   |> Event.Query.by_event_type("oauth.refresh_token_reused")
                   |> Repo.all()

          assert client_id == state.client.id
        after
          stop_tasks(refreshers)
        end
      after
        send(blocker.pid, :release)
        stop_tasks([blocker])
      end
    end)
  end

  defp unboxed_oauth(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      user = Fixtures.Users.create_user(%{email: "oauth-race-#{suffix}@example.test"})

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "OAuth race #{suffix}", slug: "oauth-race-#{suffix}"},
          user
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      {:ok, client} =
        OAuth.register_client(%{
          "client_name" => "OAuth race",
          "redirect_uris" => [@redirect]
        })

      verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

      {:ok, code, @redirect} =
        OAuth.issue_code(
          client,
          %{
            "redirect_uri" => @redirect,
            "response_type" => "code",
            "code_challenge" => challenge,
            "code_challenge_method" => "S256",
            "scope" => "mcp offline_access",
            "resource" => @resource
          },
          subject
        )

      {:ok, tokens} =
        OAuth.exchange_code(%{
          "code" => code,
          "client_id" => client.id,
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        })

      token = Repo.get_by!(Token, access_token_hash: Emisar.Crypto.hash(tokens.access_token))
      key = Repo.get!(ApiKey, token.api_key_id)

      try do
        fun.(%{account: account, client: client, key: key, tokens: tokens})
      after
        Repo.delete_all(from(account in Account, where: account.id == ^account.id))
        Repo.delete_all(from(client in Client, where: client.id == ^client.id))
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

  defp start_refresher(state, parent, index) do
    unboxed_task(fn ->
      send(parent, {:refresher_started, index, backend_pid()})

      OAuth.refresh(%{
        "refresh_token" => state.tokens.refresh_token,
        "client_id" => state.client.id
      })
    end)
  end

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp blocked_by?(blocked_backend, blocking_backend) do
    query = "SELECT $2::integer = ANY(pg_blocking_pids($1::integer))"
    Repo.query!(query, [blocked_backend, blocking_backend]).rows == [[true]]
  end

  defp await_blocked(backend, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    query = "SELECT cardinality(pg_blocking_pids($1::integer)) > 0"

    cond do
      Repo.query!(query, [backend]).rows == [[true]] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("backend #{backend} was never blocked")

      true ->
        await_blocked(backend, deadline)
    end
  end

  defp stop_tasks(tasks) do
    Enum.each(tasks, fn task ->
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end)
  end
end
