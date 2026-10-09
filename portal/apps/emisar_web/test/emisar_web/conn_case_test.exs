defmodule EmisarWeb.ConnCaseTest do
  @moduledoc """
  `register_and_log_in/2` runs inside each async test's own sandbox transaction,
  which cannot see another test's uncommitted rows. A default slug derived from
  the shared "Test Co" name therefore passed `Accounts.suggest_unique_slug/1`'s
  read-before-insert check in two tests at once, and the second INSERT queued
  on the `accounts.slug` unique index until the first test finished. Each case
  here runs two writers on their own sandbox connections to prove the boundary.
  """
  use EmisarWeb.ConnCase, async: true
  import Emisar.ConcurrencyCase, only: [await_blocked_by: 2, backend_pid: 0]
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.Accounts
  alias Emisar.Accounts.Account
  alias Emisar.Repo

  describe "register_and_log_in/2" do
    test "two isolated owners deriving a slug from one name queue on the unique index" do
      name = "Collide #{Fixtures.Random.unique_int()}"
      parent = self()

      first =
        isolated_owner(fn ->
          send(parent, {:first_backend, backend_pid()})
          {_conn, _owner, account} = register_default_shape(name)
          send(parent, {:first_slug, account.slug})

          receive do
            :release -> :released
          end
        end)

      assert_receive {:first_backend, first_backend}, 5_000
      assert_receive {:first_slug, first_slug}, 5_000, owner_diagnostics(first, first_backend)

      second =
        isolated_owner(fn ->
          send(parent, {:second_backend, backend_pid()})
          {_conn, _owner, account} = register_default_shape(name)
          account
        end)

      assert_receive {:second_backend, second_backend}, 5_000
      await_blocked_by(second_backend, first_backend)

      send(first.pid, :release)
      assert Task.await(first, 5_000) == :released
      # The rollback frees the slug both owners chose, so the queued INSERT lands it.
      assert %Account{slug: ^first_slug} = Task.await(second, 5_000)
    end

    test "the default slug stays distinct while another owner holds an uncommitted account" do
      parent = self()

      first =
        isolated_owner(fn ->
          send(parent, {:first_backend, backend_pid()})
          {_conn, _owner, account} = register_and_log_in(Phoenix.ConnTest.build_conn())
          send(parent, {:first_account, account})

          receive do
            :release -> :released
          end
        end)

      assert_receive {:first_backend, first_backend}, 5_000

      assert_receive {:first_account, %Account{} = first_account},
                     5_000,
                     owner_diagnostics(first, first_backend)

      second =
        isolated_owner(fn ->
          {_conn, _owner, account} = register_and_log_in(Phoenix.ConnTest.build_conn())
          account
        end)

      assert {:ok, %Account{} = second_account} = Task.yield(second, 5_000)
      send(first.pid, :release)
      assert Task.await(first, 5_000) == :released

      assert first_account.name == "Test Co"
      assert second_account.name == "Test Co"
      assert first_account.slug != second_account.slug
    end
  end

  describe "log_in_member/3" do
    test "appends one real entry per workspace, all minted for this browser", %{conn: conn} do
      {owner_a, account_a, _subject_a} = Fixtures.Subjects.owner_subject()
      {owner_b, account_b, _subject_b} = Fixtures.Subjects.owner_subject()

      conn = conn |> log_in_member(owner_a) |> log_in_member(owner_b)
      browser_id = get_session(conn, :browser_id)

      assert [{first_account, token_a}, {second_account, token_b}] = get_session(conn, :sessions)
      assert {first_account, second_account} == {account_a.id, account_b.id}

      for {token, account} <- [{token_a, account_a}, {token_b, account_b}] do
        assert {:ok, session} = Emisar.Auth.fetch_session_by_token(token, account.id)
        assert session.auth_method == :magic_link
        assert session.browser_digest == Emisar.Crypto.hash(browser_id)
      end

      assert session_token(conn, account_b) == token_b
    end

    test "a second sign-in to the same workspace replaces its entry", %{conn: conn} do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()

      first = log_in_member(conn, owner)
      second = log_in_member(first, owner)

      assert [{account_id, token}] = get_session(second, :sessions)
      assert account_id == account.id
      refute token == session_token(first, account)
      assert get_session(second, :browser_id) == get_session(first, :browser_id)
    end

    test "carries SSO provenance and a proved second factor when asked", %{conn: conn} do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      identity = Fixtures.SSO.create_user_identity(provider_id: provider.id, membership: owner)

      conn =
        log_in_member(conn, owner, auth_method: :sso, user_identity_id: identity.id, mfa: true)

      assert {:ok, session} =
               Emisar.Auth.fetch_session_by_token(session_token(conn, account), account.id)

      assert session.auth_method == :sso
      assert session.user_identity_id == identity.id
      assert %DateTime{} = session.mfa_verified_at
    end
  end

  defp owner_diagnostics(task, backend) do
    process = Process.info(task.pid, [:current_stacktrace, :status, :reductions])

    query = """
    SELECT state, wait_event_type, wait_event, pg_blocking_pids(pid), xact_start, query_start, query
    FROM pg_stat_activity WHERE pid = $1
    """

    %{rows: rows} = Repo.query!(query, [backend])

    loaders =
      Map.new([:code_server, :erl_prim_loader, :file_server_2], fn name ->
        info =
          case Process.whereis(name) do
            nil ->
              nil

            pid ->
              Process.info(pid, [:current_stacktrace, :status, :message_queue_len, :reductions])
          end

        {name, info}
      end)

    "Isolated owner did not finish registration: #{inspect(%{process: process, database: rows, loaders: loaders})}"
  end

  # Runs `fun` as its own sandbox owner on a separate connection. Dropping
  # `$callers` keeps the task out of the test's transaction; checking out in the
  # task process itself means a crash returns the connection with the process.
  defp isolated_owner(fun) do
    Task.async(fn ->
      Process.delete(:"$callers")
      :ok = Sandbox.checkout(Repo)

      try do
        fun.()
      after
        :ok = Sandbox.checkin(Repo)
      end
    end)
  end

  # The former default shape: a slug derived from the name by a read-before-insert.
  defp register_default_shape(name) do
    account = %{name: name, slug: Accounts.suggest_unique_slug(name)}
    register_and_log_in(Phoenix.ConnTest.build_conn(), %{account: account})
  end
end
