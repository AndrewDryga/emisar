defmodule Emisar.AuditTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Audit
  alias Emisar.Auth.Subject

  setup do
    # Each test gets a clean process; metadata stash never bleeds
    # between tests. Be paranoid in case a previous test crashed
    # without clearing.
    Audit.clear_request_metadata()
    on_exit(fn -> Audit.clear_request_metadata() end)
    :ok
  end

  describe "put_request_metadata + log/3" do
    test "log/3 picks up IP/UA/request_id stashed via put_request_metadata/1" do
      account = account_fixture()

      Audit.put_request_metadata(%{
        ip_address: "10.0.0.42",
        user_agent: "curl/8.5.0",
        request_id: "req_abc",
        mcp_session_id: "sess_xyz"
      })

      {:ok, event} = Audit.log(account.id, "audit.test", actor_kind: "system")

      assert event.ip_address == "10.0.0.42"
      assert event.user_agent == "curl/8.5.0"
      assert event.request_id == "req_abc"
      assert event.mcp_session_id == "sess_xyz"
    end

    test "explicit attrs win over process metadata" do
      account = account_fixture()
      Audit.put_request_metadata(%{ip_address: "10.0.0.42", user_agent: "curl"})

      {:ok, event} =
        Audit.log(account.id, "audit.test",
          actor_kind: "system",
          ip_address: "8.8.8.8"
        )

      assert event.ip_address == "8.8.8.8"
      # User agent NOT explicitly overridden — still picks up the
      # process value.
      assert event.user_agent == "curl"
    end

    test "with no metadata set, IP/UA/request_id are nil (no crash)" do
      account = account_fixture()

      {:ok, event} = Audit.log(account.id, "audit.test", actor_kind: "system")

      assert event.ip_address == nil
      assert event.user_agent == nil
      assert event.request_id == nil
    end

    test "clear_request_metadata wipes the stash" do
      Audit.put_request_metadata(%{ip_address: "10.0.0.42"})
      assert Audit.get_request_metadata() == %{ip_address: "10.0.0.42"}
      Audit.clear_request_metadata()
      assert Audit.get_request_metadata() == %{}
    end
  end

  describe "resolve_references/1" do
    test "returns live labels for users, runners, and api keys", %{} do
      account = account_fixture()
      user = user_fixture()
      # User labels scope through membership — stamp the membership the real
      # write path would have created. Owner role so api_key_fixture's
      # owner-subject can mint (subject_for reads the persisted membership role).
      _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
      runner = runner_fixture(account_id: account.id, name: "db-prod-01")
      {_raw, api_key} = api_key_fixture(account_id: account.id, created_by_id: user.id)

      {:ok, e_user} =
        Audit.log(account.id, "user.touched",
          actor_kind: "user",
          actor_id: user.id,
          subject_kind: "user",
          subject_id: user.id
        )

      {:ok, e_runner} =
        Audit.log(account.id, "runner.touched",
          subject_kind: "runner",
          subject_id: runner.id
        )

      {:ok, e_key} =
        Audit.log(account.id, "api_key.touched",
          subject_kind: "api_key",
          subject_id: api_key.id
        )

      refs = Audit.resolve_references([e_user, e_runner, e_key])

      assert refs["user"][user.id] == user.email
      assert refs["runner"][runner.id] == "db-prod-01"
      assert refs["api_key"][api_key.id] == api_key.name
    end

    test "missing records (deleted since the event) are simply absent" do
      account = account_fixture()
      ghost_id = Ecto.UUID.generate()

      {:ok, event} =
        Audit.log(account.id, "user.gone",
          actor_kind: "user",
          actor_id: ghost_id
        )

      refs = Audit.resolve_references([event])

      refute Map.has_key?(refs["user"], ghost_id)
    end

    test "an id stamped from another account does not resolve (account-scoped)" do
      account_a = account_fixture()
      account_b = account_fixture()

      # A runner + user that genuinely live in account B.
      runner_b = runner_fixture(account_id: account_b.id, name: "b-runner")
      user_b = user_fixture()
      _ = membership_fixture(account_id: account_b.id, user_id: user_b.id)

      # A mis-stamped audit row in account A pointing at B's ids.
      {:ok, event} =
        Audit.log(account_a.id, "cross.account",
          actor_kind: "user",
          actor_id: user_b.id,
          subject_kind: "runner",
          subject_id: runner_b.id
        )

      refs = Audit.resolve_references([event])

      refute Map.has_key?(refs["user"], user_b.id)
      refute Map.has_key?(refs["runner"], runner_b.id)
    end
  end

  describe "list_events/2 (paginated + filterable)" do
    test "page size + Next cursor walk through every row in order" do
      account = account_fixture()

      for i <- 1..7 do
        {:ok, _} =
          Audit.log(account.id, "iter.event",
            actor_kind: "system",
            payload: %{"i" => i}
          )
      end

      # First page of 3 — Next cursor points to the rest.
      assert {:ok, page1, %{next_page_cursor: cursor, count: 7}} =
               Audit.list_events(Subject.system(account), page: [limit: 3])

      assert length(page1) == 3
      assert is_binary(cursor)

      {:ok, page2, %{next_page_cursor: cursor2}} =
        Audit.list_events(Subject.system(account), page: [cursor: cursor, limit: 3])

      assert length(page2) == 3

      {:ok, page3, %{next_page_cursor: nil}} =
        Audit.list_events(Subject.system(account), page: [cursor: cursor2, limit: 3])

      # Last page tail — 7 - 3 - 3 = 1 row.
      assert length(page3) == 1

      # No row repeated across pages — keyset pagination invariant.
      ids = Enum.map(page1 ++ page2 ++ page3, & &1.id)
      assert ids == Enum.uniq(ids)
    end

    test "filter list narrows to matching event_types only" do
      account = account_fixture()

      # Use real known event_type values — the filter now validates
      # against `Event.Query.known_event_type_values/0` so the UI
      # dropdown shows curated options instead of free-text.
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "policy.updated", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user")

      {:ok, rows, %{count: 2}} =
        Audit.list_events(Subject.system(account), filter: [event_type: ["user.invited"]])

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.event_type == "user.invited"))
    end

    test "actor_kind list filter accepts a list of kinds" do
      account = account_fixture()

      {:ok, _} = Audit.log(account.id, "x", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "api_key")
      {:ok, _} = Audit.log(account.id, "x", actor_kind: "system")

      {:ok, rows, _} =
        Audit.list_events(Subject.system(account), filter: [actor_kind: ["user", "api_key"]])

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.actor_kind in ["user", "api_key"]))
    end

    test "invalid cursor surfaces an error rather than returning random rows" do
      account = account_fixture()

      assert {:error, :invalid_cursor} =
               Audit.list_events(Subject.system(account), page: [cursor: "garbage"])
    end

    test "hide_noise filter excludes the canonical noisy event types" do
      account = account_fixture()

      # One of each: 2 noisy types + 2 operator-facing types.
      {:ok, _} = Audit.log(account.id, "policy.evaluated", actor_kind: "system")
      {:ok, _} = Audit.log(account.id, "runner.connected", actor_kind: "runner")
      {:ok, _} = Audit.log(account.id, "approval.approved", actor_kind: "user")
      {:ok, _} = Audit.log(account.id, "user.invited", actor_kind: "user")

      {:ok, rows, %{count: 2}} =
        Audit.list_events(Subject.system(account), filter: [hide_noise: true])

      kept = Enum.map(rows, & &1.event_type) |> Enum.sort()
      assert kept == ["approval.approved", "user.invited"]
    end

    test "hide_noise off (default) keeps everything" do
      account = account_fixture()
      {:ok, _} = Audit.log(account.id, "policy.evaluated", actor_kind: "system")
      {:ok, _} = Audit.log(account.id, "approval.approved", actor_kind: "user")

      {:ok, rows, %{count: 2}} = Audit.list_events(Subject.system(account))
      assert length(rows) == 2
    end
  end
end
