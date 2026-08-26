defmodule EmisarWeb.AuditDownloadConcurrencyTest do
  use ExUnit.Case, async: false
  use EmisarWeb, :verified_routes
  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.{Accounts, Audit, Config, Fixtures, Repo}
  alias Emisar.Accounts.Account
  alias Emisar.Users.User

  @endpoint EmisarWeb.Endpoint
  @moduletag timeout: 60_000

  test "growth after the exact preflight cannot cross the final-page row cap" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      owner_email = "audit-csv-growth-#{suffix}@example.test"
      owner = Fixtures.Users.create_user(%{email: owner_email})

      {:ok, account} =
        Accounts.create_account_with_owner(
          %{name: "Audit CSV growth #{suffix}", slug: "audit-csv-growth-#{suffix}"},
          owner
        )

      token = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)

      for label <- ["one", "two"] do
        {:ok, _event} =
          Audit.log(account.id, "user.invited", actor_kind: "user", actor_label: label)
      end

      parent = self()

      blocker =
        unboxed_task(fn ->
          blocker_backend = backend_pid()

          Repo.transaction(fn ->
            _account =
              Repo.one!(
                from(stored in Account,
                  where: stored.id == ^account.id,
                  lock: "FOR UPDATE"
                )
              )

            send(parent, {:audit_csv_account_locked, blocker_backend})

            receive do
              :grow_and_release_audit_csv ->
                {:ok, _event} =
                  Audit.log(account.id, "user.invited",
                    actor_kind: "user",
                    actor_label: "three"
                  )

                :ok

              :release_audit_csv_account ->
                :ok
            end
          end)
        end)

      assert_receive {:audit_csv_account_locked, blocker_backend}, 5_000

      request =
        unboxed_task(fn ->
          Config.put_override(:emisar_web, :audit_download_max_rows, 2)
          request_backend = backend_pid()
          send(parent, {:audit_csv_request_started, request_backend})

          build_conn()
          |> init_test_session(%{})
          |> put_session(:user_token, token)
          |> post(~p"/app/#{account}/audit/download?event_type=user.invited")
        end)

      assert_receive {:audit_csv_request_started, request_backend}, 5_000

      try do
        # The request counted exactly two events, then reached the account-row
        # reservation and blocked behind this test's lock. Add a third before
        # releasing it so the single final page is larger than the preflight.
        await_blocked_by(request_backend, blocker_backend)

        send(blocker.pid, :grow_and_release_audit_csv)
        assert {:ok, _account} = Task.await(blocker, 30_000)
        response = Task.await(request, 30_000)

        assert redirected_to(response) ==
                 ~p"/app/#{account}/audit?event_type=user.invited"

        assert Phoenix.Flash.get(response.assigns.flash, :error) =~ "now too large"
        assert get_resp_header(response, "content-disposition") == []

        account = Repo.reload!(account)
        refute account.one_time_audit_csv_exported_at
        refute account.one_time_audit_csv_export_reservation_id

        refute Repo.all(Audit.Event)
               |> Enum.any?(&(&1.account_id == account.id and &1.event_type == "audit.exported"))
      after
        send(blocker.pid, :release_audit_csv_account)
        stop_tasks([blocker, request])
        Repo.delete_all(from(stored in Account, where: stored.id == ^account.id))
        Repo.delete_all(from(stored in User, where: stored.id == ^owner.id))
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

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("audit CSV request never reached the post-preflight reservation lock")

      true ->
        tick = make_ref()
        Process.send_after(self(), {:audit_csv_lock_tick, tick}, 10)
        assert_receive {:audit_csv_lock_tick, ^tick}, 100
        await_blocked_by(blocked_backend, blocking_backend, deadline)
    end
  end
end
