defmodule Emisar.RunnersTest do
  use Emisar.DataCase, async: true
  alias Emisar.Audit
  alias Emisar.Auth.Subject
  alias Emisar.Billing
  alias Emisar.Fixtures
  alias Emisar.Repo
  alias Emisar.RequestContext
  alias Emisar.Runners
  alias Emisar.Runners.{AuthKey, Presence, Runner, Token}

  defp account_with_owner_subject do
    user = Fixtures.Users.create_user()
    account = Fixtures.Accounts.create_account()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    {account, user, subject}
  end

  defp filter_names(subject, status) do
    {:ok, runners, _} = Runners.list_runners_for_account(subject, status: status)
    runners |> Enum.map(& &1.name) |> Enum.sort()
  end

  describe "runner_labels_for_ids/1" do
    test "returns a %{id => name} map for the supplied ids" do
      r1 = Fixtures.Runners.create_runner(name: "alpha", connected?: false)
      r2 = Fixtures.Runners.create_runner(name: "bravo", connected?: false)

      assert Runners.runner_labels_for_ids([r1.id, r2.id]) == %{
               r1.id => "alpha",
               r2.id => "bravo"
             }
    end

    test "an empty id list short-circuits to an empty map (no query)" do
      assert Runners.runner_labels_for_ids([]) == %{}
      # nils are dropped, so an all-nil list is also empty.
      assert Runners.runner_labels_for_ids([nil, nil]) == %{}
    end

    test "still labels a SOFT-DELETED runner — deliberately all(), not not_deleted()" do
      # Runs + audit rows keep FKs to soft-deleted runners, so their labels must
      # still render in history views. The batcher uses all() for exactly this.
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "ghost")
      {:ok, _} = Runners.delete_runner(runner, subject)

      assert Runners.runner_labels_for_ids([runner.id]) == %{runner.id => "ghost"}
    end
  end

  describe "list_runners_for_account/2" do
    test "filters by account, group, and status" do
      {account, _user, subject} = account_with_owner_subject()
      other_account = Fixtures.Accounts.create_account()

      _ = Fixtures.Runners.create_runner(account_id: account.id, group: "web", connected?: true)
      _ = Fixtures.Runners.create_runner(account_id: account.id, group: "db", connected?: false)
      _ = Fixtures.Runners.create_runner(account_id: other_account.id, group: "web")

      assert {:ok, list, _} = Runners.list_runners_for_account(subject)
      assert length(list) == 2
      assert {:ok, list, _} = Runners.list_runners_for_account(subject, group: "web")
      assert length(list) == 1

      # connected? tracks presence from this process, so the "connected"
      # filter resolves the online id set and returns just that runner.
      assert {:ok, list, _} = Runners.list_runners_for_account(subject, status: "connected")
      assert length(list) == 1
    end

    test "the status filter resolves each connection state via presence ids" do
      {account, _user, subject} = account_with_owner_subject()
      topic = Presence.topic(account.id)

      _online =
        Fixtures.Runners.create_runner(account_id: account.id, name: "r-online", connected?: true)

      _pending =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "r-pending",
          connected?: false
        )

      # Connected then dropped from presence = "disconnected": last_connected_at
      # is set but the socket is no longer live.
      disc =
        Fixtures.Runners.create_runner(account_id: account.id, name: "r-disc", connected?: true)

      :ok = Presence.untrack(self(), topic, disc.id)

      disabled =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "r-disabled",
          connected?: false
        )

      {:ok, _} = Runners.disable_runner(disabled, subject)

      assert filter_names(subject, "connected") == ["r-online"]
      assert filter_names(subject, "disconnected") == ["r-disc"]
      assert filter_names(subject, "pending") == ["r-pending"]
      assert filter_names(subject, "disabled") == ["r-disabled"]
    end

    test "decorates online?, action_load + last heartbeat from presence" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      {:ok, _ref} = Runners.record_heartbeat(account.id, runner.id, 5)

      assert {:ok, [listed], _} = Runners.list_runners_for_account(subject)
      assert listed.online?
      assert listed.action_load == 5
    end

    test "a viewer subject (no view_runners) is unauthorized" do
      account = Fixtures.Accounts.create_account()
      no_view = %Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert {:error, :unauthorized} = Runners.list_runners_for_account(no_view)
    end
  end

  describe "list_all_runners_for_account/1" do
    test "returns every runner — no pagination cap — decorated + account-scoped" do
      {account, _user, subject} = account_with_owner_subject()

      # 40 runners — past the paginator's 35-row default page.
      for _ <- 1..40,
          do: Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      {:ok, all} = Runners.list_all_runners_for_account(subject)
      assert length(all) == 40
      # Presence-decorated: the virtual field is populated, not left unloaded.
      assert Enum.all?(all, &(&1.online? == false))

      # The UI reader is deliberately left paginated.
      assert {:ok, paged, _meta} = Runners.list_runners_for_account(subject)
      assert length(paged) == 35

      # Another account sees none of them.
      {_other, _u, other_subject} = account_with_owner_subject()
      assert {:ok, []} = Runners.list_all_runners_for_account(other_subject)
    end

    test "a viewer subject (no view_runners) is unauthorized" do
      account = Fixtures.Accounts.create_account()
      no_view = %Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert {:error, :unauthorized} = Runners.list_all_runners_for_account(no_view)
    end
  end

  describe "list_group_summaries/1" do
    test "returns {group, count} tuples for the account's non-deleted runners" do
      {account, _user, subject} = account_with_owner_subject()
      _ = Fixtures.Runners.create_runner(account_id: account.id, group: "web", connected?: false)
      _ = Fixtures.Runners.create_runner(account_id: account.id, group: "web", connected?: false)
      _ = Fixtures.Runners.create_runner(account_id: account.id, group: "db", connected?: false)

      assert {:ok, rows} = Runners.list_group_summaries(subject)
      assert Enum.sort(rows) == [{"db", 1}, {"web", 2}]
    end

    test "is account-scoped — another account's groups don't leak in" do
      {_account_a, _ua, subject_a} = account_with_owner_subject()
      other = Fixtures.Accounts.create_account()
      _ = Fixtures.Runners.create_runner(account_id: other.id, group: "secret", connected?: false)

      assert {:ok, []} = Runners.list_group_summaries(subject_a)
    end

    test "a viewer subject (no view_runners) is unauthorized" do
      account = Fixtures.Accounts.create_account()
      no_view = %Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert {:error, :unauthorized} = Runners.list_group_summaries(no_view)
    end
  end

  describe "fetch_runner_by_id/3" do
    setup do
      {account, _user, subject} = account_with_owner_subject()
      %{account: account, subject: subject}
    end

    test "fetches a non-deleted runner by id, presence-decorated", %{
      account: account,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      {:ok, _ref} = Runners.record_heartbeat(account.id, runner.id, 5)

      assert {:ok, fetched} = Runners.fetch_runner_by_id(runner.id, subject)
      assert fetched.id == runner.id
      assert fetched.online?
      assert fetched.action_load == 5
      assert %DateTime{} = fetched.last_heartbeat_at
    end

    test "a malformed (non-UUID) id is :not_found, never a crash", %{subject: subject} do
      assert {:error, :not_found} = Runners.fetch_runner_by_id("not-a-uuid", subject)
    end

    test "a runner in another account is :not_found (cross-account isolation)", %{
      subject: subject_a
    } do
      account_b = Fixtures.Accounts.create_account()
      runner_b = Fixtures.Runners.create_runner(account_id: account_b.id)

      assert {:error, :not_found} = Runners.fetch_runner_by_id(runner_b.id, subject_a)
    end

    test "a subject without view_runners is unauthorized", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      no_view = %Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert {:error, :unauthorized} = Runners.fetch_runner_by_id(runner.id, no_view)
    end
  end

  describe "fetch_runner_by_name/3" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "fetches a non-deleted runner by its account-unique name", %{
      account: account,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "host-1")

      assert {:ok, fetched} = Runners.fetch_runner_by_name("host-1", subject)
      assert fetched.id == runner.id
    end

    test "not_found for an unknown name", %{subject: subject} do
      assert {:error, :not_found} = Runners.fetch_runner_by_name("nope", subject)
    end

    test "cross-account: a name in another account doesn't resolve", %{subject: subject_a} do
      account_b = Fixtures.Accounts.create_account()
      _runner = Fixtures.Runners.create_runner(account_id: account_b.id, name: "host-b")

      assert {:error, :not_found} = Runners.fetch_runner_by_name("host-b", subject_a)
    end

    test "denial: a subject without view_runners is unauthorized", %{account: account} do
      _runner = Fixtures.Runners.create_runner(account_id: account.id, name: "host-1")
      no_view = %Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert {:error, :unauthorized} = Runners.fetch_runner_by_name("host-1", no_view)
    end
  end

  describe "runner_active_in_account?/2" do
    test "true for a live, non-disabled runner in the account" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      assert Runners.runner_active_in_account?(runner.id, runner.account_id)
    end

    test "false for a disabled runner (a disabled runner refuses new dispatch)" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, _} = Runners.disable_runner(runner, subject)

      refute Runners.runner_active_in_account?(runner.id, account.id)
    end

    test "false for a soft-deleted runner" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, _} = Runners.delete_runner(runner, subject)

      refute Runners.runner_active_in_account?(runner.id, account.id)
    end

    test "false across accounts — the runner isn't active in a different account" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      other = Fixtures.Accounts.create_account()

      refute Runners.runner_active_in_account?(runner.id, other.id)
    end
  end

  describe "any_runner_bootstrapped_by_key?/3" do
    test "true when a listed runner registered with that key" do
      account = Fixtures.Accounts.create_account()
      {_raw, key} = Fixtures.Runners.create_auth_key(account_id: account.id)

      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          bootstrap_auth_key_id: key.id,
          connected?: false
        )

      assert Runners.any_runner_bootstrapped_by_key?([runner.id], key.id, account.id)
    end

    test "false when the listed runner registered with a different key" do
      account = Fixtures.Accounts.create_account()
      {_raw, key} = Fixtures.Runners.create_auth_key(account_id: account.id)
      {_raw, other_key} = Fixtures.Runners.create_auth_key(account_id: account.id)

      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          bootstrap_auth_key_id: other_key.id,
          connected?: false
        )

      refute Runners.any_runner_bootstrapped_by_key?([runner.id], key.id, account.id)
    end

    test "false when the key's runner exists but its id isn't in the list" do
      account = Fixtures.Accounts.create_account()
      {_raw, key} = Fixtures.Runners.create_auth_key(account_id: account.id)

      _bootstrapped =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          bootstrap_auth_key_id: key.id,
          connected?: false
        )

      unrelated = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      # The install page checks only the runners that just joined presence — a
      # different runner from the same key connecting elsewhere mustn't count.
      refute Runners.any_runner_bootstrapped_by_key?([unrelated.id], key.id, account.id)
    end

    test "false across accounts — scoped to the given account only" do
      account = Fixtures.Accounts.create_account()
      {_raw, key} = Fixtures.Runners.create_auth_key(account_id: account.id)

      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          bootstrap_auth_key_id: key.id,
          connected?: false
        )

      other = Fixtures.Accounts.create_account()

      refute Runners.any_runner_bootstrapped_by_key?([runner.id], key.id, other.id)
    end
  end

  describe "runner_enforces_signatures?/2" do
    test "true for an enforcing runner, false for a plain one" do
      enforcing = Fixtures.Runners.create_runner(enforce_signatures: true)
      plain = Fixtures.Runners.create_runner()

      assert Runners.runner_enforces_signatures?(enforcing.id, enforcing.account_id)
      refute Runners.runner_enforces_signatures?(plain.id, plain.account_id)
    end

    test "is account-scoped — the enforcing runner doesn't enforce in another account" do
      account_b = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(enforce_signatures: true)

      assert Runners.runner_enforces_signatures?(runner.id, runner.account_id)
      refute Runners.runner_enforces_signatures?(runner.id, account_b.id)
    end
  end

  describe "list_active_runners_in_groups/2" do
    test "returns active runners in the groups, name-ordered" do
      account = Fixtures.Accounts.create_account()

      _b =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          group: "web",
          name: "bravo",
          connected?: false
        )

      _a =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          group: "web",
          name: "alpha",
          connected?: false
        )

      _other =
        Fixtures.Runners.create_runner(account_id: account.id, group: "db", connected?: false)

      names =
        Runners.list_active_runners_in_groups(account.id, ["web"]) |> Enum.map(& &1.name)

      assert names == ["alpha", "bravo"]
    end

    test "an empty group list short-circuits to []" do
      assert Runners.list_active_runners_in_groups(Ecto.UUID.generate(), []) == []
    end

    test "excludes disabled and soft-deleted runners" do
      {account, _user, subject} = account_with_owner_subject()

      live =
        Fixtures.Runners.create_runner(account_id: account.id, group: "web", connected?: false)

      disabled =
        Fixtures.Runners.create_runner(account_id: account.id, group: "web", connected?: false)

      {:ok, _} = Runners.disable_runner(disabled, subject)

      deleted =
        Fixtures.Runners.create_runner(account_id: account.id, group: "web", connected?: false)

      {:ok, _} = Runners.delete_runner(deleted, subject)

      ids = Runners.list_active_runners_in_groups(account.id, ["web"]) |> Enum.map(& &1.id)
      assert ids == [live.id]
    end

    test "is account-scoped — another account's same-group runner is excluded" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()

      _ =
        Fixtures.Runners.create_runner(account_id: account_b.id, group: "web", connected?: false)

      assert Runners.list_active_runners_in_groups(account_a.id, ["web"]) == []
    end
  end

  describe "count_billable_runners/1" do
    test "counts active runners as an integer; +1 per added runner" do
      account = Fixtures.Accounts.create_account()

      assert Runners.count_billable_runners(account.id) == 0
      assert is_integer(Runners.count_billable_runners(account.id))

      _ = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      assert Runners.count_billable_runners(account.id) == 1
    end

    test "disabled and soft-deleted runners don't occupy a slot" do
      {account, _user, subject} = account_with_owner_subject()
      _live = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      disabled = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      deleted = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      {:ok, _} = Runners.disable_runner(disabled, subject)
      {:ok, _} = Runners.delete_runner(deleted, subject)

      assert Runners.count_billable_runners(account.id) == 1
    end

    test "is account-scoped" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      _ = Fixtures.Runners.create_runner(account_id: account_b.id, connected?: false)

      assert Runners.count_billable_runners(account_a.id) == 0
    end
  end

  describe "connection_counts/0 (fleet-wide telemetry sampler)" do
    test "an empty fleet is all zeros" do
      assert %{connected: 0, disconnected: 0, never_connected: 0, disabled: 0} =
               Runners.connection_counts()
    end

    test "classifies each connection-record state, fleet-wide across accounts" do
      now = DateTime.utc_now()
      earlier = DateTime.add(now, -60, :second)

      # `connected?: false` skips the fixture's last_connected_at stamp + presence
      # tracking, so each test sets exactly the connection-record state it wants.
      never = fn -> Fixtures.Runners.create_runner(connected?: false) end

      # never-connected: no connection timestamps, across two accounts.
      _ = never.()

      _ =
        Fixtures.Runners.create_runner(
          connected?: false,
          account_id: Fixtures.Accounts.create_account().id
        )

      # connected: last connect is the most recent event (no disconnect, or older).
      _ = never.() |> put_connection(last_connected_at: now)
      _ = never.() |> put_connection(last_connected_at: now, last_disconnected_at: earlier)

      # disconnected: last disconnect is at/after the last connect.
      _ = never.() |> put_connection(last_connected_at: earlier, last_disconnected_at: now)

      # disabled: counted as disabled regardless of its connection timestamps.
      _ = never.() |> put_connection(last_connected_at: now, disabled_at: now)

      # deleted: excluded from every bucket.
      _ = never.() |> put_connection(last_connected_at: now, deleted_at: now)

      assert %{connected: 2, disconnected: 1, never_connected: 2, disabled: 1} =
               Runners.connection_counts()
    end
  end

  describe "peek_runner_by_id/1" do
    test "returns the runner struct for a live id" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      assert %Runner{id: id} = Runners.peek_runner_by_id(runner.id)
      assert id == runner.id
    end

    test "returns nil for a soft-deleted runner" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, _} = Runners.delete_runner(runner, subject)

      assert is_nil(Runners.peek_runner_by_id(runner.id))
    end

    test "returns nil for an unused or malformed id (no crash)" do
      assert is_nil(Runners.peek_runner_by_id(Ecto.UUID.generate()))
      assert is_nil(Runners.peek_runner_by_id("not-a-uuid"))
    end
  end

  describe "fetch_runner_by_external_id_for_account/2" do
    test "resolves a live runner by (account, external_id)" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, external_id: "ext-1")

      assert {:ok, %Runner{id: id}} =
               Runners.fetch_runner_by_external_id_for_account("ext-1", account.id)

      assert id == runner.id
    end

    test "is account-scoped — the same external_id in another account is :not_found" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      _ = Fixtures.Runners.create_runner(account_id: account_a.id, external_id: "shared")

      assert {:error, :not_found} =
               Runners.fetch_runner_by_external_id_for_account("shared", account_b.id)
    end

    test "a soft-deleted runner no longer resolves (frees its external_id)" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, external_id: "recycle")
      {:ok, _} = Runners.delete_runner(runner, subject)

      assert {:error, :not_found} =
               Runners.fetch_runner_by_external_id_for_account("recycle", account.id)
    end
  end

  describe "create_runner/2" do
    setup do
      {account, _user, subject} = account_with_owner_subject()
      %{account: account, subject: subject}
    end

    test "creates a runner in the subject's account", %{account: account, subject: subject} do
      assert {:ok, %Runner{} = runner} =
               Runners.create_runner(%{"name" => "edge-01", "group" => "edge"}, subject)

      assert runner.account_id == account.id
      assert runner.name == "edge-01"
      assert runner.group == "edge"
    end

    test "an OFFLINE holder conflicts the same as a connected one", %{
      account: account,
      subject: subject
    } do
      holder =
        Fixtures.Runners.create_runner(account_id: account.id, name: "edge-01", connected?: false)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Runners.create_runner(%{"name" => "edge-01", "group" => "edge"}, subject)

      assert "is already used by another runner in this account" in errors_on(changeset).name
      assert %Runner{} = Runners.peek_runner_by_id(holder.id)
    end

    test "keeps the conflict when the holder is CONNECTED", %{account: account, subject: subject} do
      holder =
        Fixtures.Runners.create_runner(account_id: account.id, name: "edge-01", connected?: true)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Runners.create_runner(%{"name" => "edge-01", "group" => "edge"}, subject)

      assert "is already used by another runner in this account" in errors_on(changeset).name
      assert %Runner{} = Runners.peek_runner_by_id(holder.id)
    end

    test "a viewer (no manage_runners) is refused", %{account: account} do
      assert {:error, :unauthorized} =
               Runners.create_runner(
                 %{"name" => "v-1", "group" => "g"},
                 viewer_subject_for(account)
               )
    end
  end

  describe "disable_runner/2" do
    setup do
      {account, _user, subject} = account_with_owner_subject()
      %{account: account, subject: subject}
    end

    test "sets disabled_at and broadcasts :runner_socket_revoked to drop the live socket", %{
      account: account,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      # The live socket subscribes to the transport topic at connect; the
      # broadcast drops an already-open (now disabled) runner's session.
      Runners.subscribe_runner_transport(runner)

      assert {:ok, %Runner{disabled_at: %DateTime{}}} = Runners.disable_runner(runner, subject)
      assert_receive :runner_socket_revoked
    end

    test "a viewer (no manage_runners) is refused", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert {:error, :unauthorized} = Runners.disable_runner(runner, viewer_subject_for(account))
    end

    test "won't touch a runner in another account (cross-account → :not_found)" do
      {account_a, _ua, _owner_a} = account_with_owner_subject()
      {_account_b, _ub, owner_b} = account_with_owner_subject()
      runner_a = Fixtures.Runners.create_runner(account_id: account_a.id)

      assert {:error, :not_found} = Runners.disable_runner(runner_a, owner_b)
    end
  end

  describe "enable_runner/2" do
    setup do
      {account, _user, subject} = account_with_owner_subject()
      %{account: account, subject: subject}
    end

    test "re-enables a disabled runner (clears disabled_at)", %{
      account: account,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, disabled} = Runners.disable_runner(runner, subject)
      assert disabled.disabled_at

      assert {:ok, enabled} = Runners.enable_runner(disabled, subject)
      assert is_nil(enabled.disabled_at)
    end

    test "a viewer can't enable a runner", %{account: account, subject: owner} do
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, disabled} = Runners.disable_runner(runner, owner)

      assert {:error, :unauthorized} =
               Runners.enable_runner(disabled, viewer_subject_for(account))
    end

    test "won't enable a runner from another account", %{account: account_a, subject: owner_a} do
      {_account_b, _ub, owner_b} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account_a.id, connected?: false)
      {:ok, disabled} = Runners.disable_runner(runner, owner_a)

      assert {:error, :not_found} = Runners.enable_runner(disabled, owner_b)
    end

    test "refuses to enable past the plan limit (free = 3)", %{account: account, subject: subject} do
      to_disable = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, disabled} = Runners.disable_runner(to_disable, subject)

      # Fill all three active slots while it's disabled, then try to claim a
      # fourth by re-enabling.
      for _ <- 1..3, do: Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      assert {:error, :over_limit, "free", 3} = Runners.enable_runner(disabled, subject)
    end
  end

  describe "delete_runner/2" do
    setup do
      {account, _user, subject} = account_with_owner_subject()
      %{account: account, subject: subject}
    end

    test "soft-deletes (sets deleted_at) and broadcasts :runner_socket_revoked", %{
      account: account,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      Runners.subscribe_runner_transport(runner)

      assert {:ok, %Runner{deleted_at: %DateTime{}}} = Runners.delete_runner(runner, subject)
      assert_receive :runner_socket_revoked
      # Gone from the default scope; history (peek uses not_deleted) returns nil.
      assert is_nil(Runners.peek_runner_by_id(runner.id))
    end

    test "a viewer (no manage_runners) is refused", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert {:error, :unauthorized} = Runners.delete_runner(runner, viewer_subject_for(account))
    end

    test "won't touch a runner in another account (cross-account → :not_found)" do
      {account_a, _ua, _owner_a} = account_with_owner_subject()
      {_account_b, _ub, owner_b} = account_with_owner_subject()
      runner_a = Fixtures.Runners.create_runner(account_id: account_a.id)

      assert {:error, :not_found} = Runners.delete_runner(runner_a, owner_b)
    end
  end

  describe "apply_state/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      %{account: account}
    end

    test "a config runner.group rename propagates on the next reconnect", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "old-group")

      {:ok, updated} =
        Runners.apply_state(runner, %{
          "group" => "new-group",
          "hostname" => "h1",
          "packs" => %{}
        })

      assert updated.group == "new-group"
    end

    test "keeps the existing group when the payload's group is blank or missing", %{
      account: account
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "keep-me")

      assert {:ok, blank} = Runners.apply_state(runner, %{"group" => ""})
      assert blank.group == "keep-me"

      assert {:ok, missing} = Runners.apply_state(runner, %{"hostname" => "h2"})
      assert missing.group == "keep-me"
    end

    test "sets enforce_signatures when the runner advertises it", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      refute runner.enforce_signatures

      {:ok, updated} = Runners.apply_state(runner, %{"enforce_signatures" => true})
      assert updated.enforce_signatures
    end

    test "clears enforce_signatures when a later advertisement omits it", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id, enforce_signatures: true)
      assert runner.enforce_signatures

      # The latest advertisement is authoritative: a reconnect that doesn't
      # advertise enforcement (the toggle flipped off in config) clears it.
      {:ok, updated} = Runners.apply_state(runner, %{"hostname" => "h"})
      refute updated.enforce_signatures
    end

    test "absorbs runner-declared hostname/labels/version from the payload", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, updated} =
        Runners.apply_state(runner, %{
          "hostname" => "new-host",
          "labels" => %{"env" => "prod"},
          "version" => "9.9.9"
        })

      assert updated.hostname == "new-host"
      assert updated.labels == %{"env" => "prod"}
      assert updated.runner_version == "9.9.9"
    end
  end

  describe "connect_runner/1" do
    test "tracks presence and stamps last_connected_at" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      refute Runners.online?(runner.account_id, runner.id)

      assert {:ok, %Runner{last_connected_at: %DateTime{}}} = Runners.connect_runner(runner)
      assert Runners.online?(runner.account_id, runner.id)
    end
  end

  describe "record_heartbeat/3" do
    test "refreshes action_load + last heartbeat in presence metadata, not the DB" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      {:ok, _} = Runners.connect_runner(runner)

      assert {:ok, _ref} = Runners.record_heartbeat(runner.account_id, runner.id, 7)

      assert %{metas: [meta | _]} =
               Runners.connection_metas(runner.account_id) |> Map.fetch!(runner.id)

      assert meta.action_load == 7
      assert is_integer(meta.last_heartbeat_at)
    end
  end

  describe "audit_runner_connected/3" do
    test "records a runner.connected audit row carrying the token id" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      context = %RequestContext{ip_address: "10.0.0.1"}

      assert {:ok, event} = Runners.audit_runner_connected(runner, "tok-123", context)
      # Reload so the payload reads back in its persisted (string-keyed) JSON form.
      event = Repo.reload!(event)
      assert event.event_type == "runner.connected"
      assert event.account_id == runner.account_id
      assert event.actor_kind == "runner"
      assert event.subject_id == runner.id
      assert event.payload["token_id"] == "tok-123"
      assert event.ip_address == "10.0.0.1"
    end
  end

  describe "audit_runner_disconnected/4" do
    test "records a runner.disconnected audit row carrying the close reason" do
      runner = Fixtures.Runners.create_runner(connected?: false)

      assert {:ok, event} =
               Runners.audit_runner_disconnected(
                 runner.account_id,
                 runner.id,
                 "going away",
                 %RequestContext{}
               )

      event = Repo.reload!(event)
      assert event.event_type == "runner.disconnected"
      assert event.account_id == runner.account_id
      assert event.subject_id == runner.id
      assert event.payload["reason"] == "going away"
    end
  end

  describe "audit_runner_error/4" do
    test "records a runner.error audit row carrying the reported payload" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      payload = %{"code" => "boom", "detail" => "pack crashed"}

      assert {:ok, event} =
               Runners.audit_runner_error(
                 runner.account_id,
                 runner.id,
                 payload,
                 %RequestContext{}
               )

      event = Repo.reload!(event)
      assert event.event_type == "runner.error"
      assert event.account_id == runner.account_id
      assert event.subject_id == runner.id
      assert event.payload["code"] == "boom"
      assert event.payload["detail"] == "pack crashed"
    end
  end

  describe "mark_disconnected/2" do
    test "stamps last_disconnected_at + reason for a runner struct" do
      runner = Fixtures.Runners.create_runner(connected?: false)

      assert {:ok, %Runner{last_disconnected_at: %DateTime{}, last_disconnect_reason: "shutdown"}} =
               Runners.mark_disconnected(runner, "shutdown")
    end

    test "id-based variant stamps the disconnect for a live id" do
      runner = Fixtures.Runners.create_runner(connected?: false)

      assert {:ok, %Runner{last_disconnected_at: %DateTime{}, last_disconnect_reason: "bye"}} =
               Runners.mark_disconnected(runner.id, "bye")
    end

    test "id-based variant returns :not_found for an unknown id" do
      assert {:error, :not_found} = Runners.mark_disconnected(Ecto.UUID.generate(), "gone")
    end
  end

  describe "online?/2" do
    test "true while a socket is tracked, false once untracked" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      assert Runners.online?(account.id, runner.id)

      :ok = Presence.untrack(self(), Presence.topic(account.id), runner.id)
      refute Runners.online?(account.id, runner.id)
    end

    test "is account-scoped — another account never sees the runner online" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account_a.id, connected?: true)

      assert Runners.online?(account_a.id, runner.id)
      refute Runners.online?(account_b.id, runner.id)
    end
  end

  describe "connection_metas/1" do
    test "returns the presence map for the account's tracked runners" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)

      assert %{metas: [_ | _]} =
               Runners.connection_metas(account.id) |> Map.fetch!(runner.id)
    end

    test "is account-scoped — an account with no presence reads as empty" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      _ = Fixtures.Runners.create_runner(account_id: account_a.id, connected?: true)

      assert Runners.connection_metas(account_b.id) == %{}
    end
  end

  describe "fleet_all_offline?/1" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "true when there are billable runners and every one is offline", %{
      account: account,
      subject: subject
    } do
      _r1 = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      _r2 = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      assert Runners.fleet_all_offline?(subject)
    end

    test "false when at least one runner is online", %{account: account, subject: subject} do
      _offline = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      online = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, _} = Runners.connect_runner(online)

      refute Runners.fleet_all_offline?(subject)
    end

    test "false when the account has no billable runners (nothing to alert on)", %{
      subject: subject
    } do
      refute Runners.fleet_all_offline?(subject)
    end

    test "false (no badge) for a subject without view_runners", %{account: account} do
      _r = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      # An in-account subject that holds no permissions — exercises the gate's
      # deny branch directly (no membership role actually lacks view_runners, so
      # the realistic no-badge caller is a runner/system subject, not a UI user).
      no_view = %Subject{account: account, role: :runner, permissions: MapSet.new()}

      refute Runners.fleet_all_offline?(no_view)
    end

    test "false for a subject with no account" do
      refute Runners.fleet_all_offline?(%Subject{})
    end
  end

  describe "fleet_all_signed?/1" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      %{account: account, subject: subject}
    end

    test "true when there's at least one active runner and every one enforces signatures", %{
      account: account,
      subject: subject
    } do
      _r1 =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          enforce_signatures: true,
          connected?: false
        )

      _r2 =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          enforce_signatures: true,
          connected?: false
        )

      assert Runners.fleet_all_signed?(subject)
    end

    test "false when any active runner does not enforce", %{account: account, subject: subject} do
      _signed =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          enforce_signatures: true,
          connected?: false
        )

      _plain = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      refute Runners.fleet_all_signed?(subject)
    end

    test "false when the account has no runners (nothing to signal)", %{subject: subject} do
      refute Runners.fleet_all_signed?(subject)
    end

    test "a disabled non-enforcing runner doesn't keep the fleet from reading signed-only", %{
      account: account,
      subject: subject
    } do
      _signed =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          enforce_signatures: true,
          connected?: false
        )

      plain = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, _} = Runners.disable_runner(plain, subject)

      assert Runners.fleet_all_signed?(subject)
    end

    test "is account-scoped — account B's enforcing fleet doesn't make account A signed", %{
      subject: subject_a
    } do
      account_b = Fixtures.Accounts.create_account()

      _r =
        Fixtures.Runners.create_runner(
          account_id: account_b.id,
          enforce_signatures: true,
          connected?: false
        )

      refute Runners.fleet_all_signed?(subject_a)
    end

    test "false (no badge) for a subject without view_runners", %{account: account} do
      _r =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          enforce_signatures: true,
          connected?: false
        )

      no_view = %Subject{account: account, role: :runner, permissions: MapSet.new()}

      refute Runners.fleet_all_signed?(no_view)
    end

    test "false for a subject with no account" do
      refute Runners.fleet_all_signed?(%Subject{})
    end
  end

  describe "connection_state/1" do
    test "maps online / disabled / pending / offline" do
      now = DateTime.utc_now()

      assert Runners.connection_state(%Runner{online?: true}) == :online
      assert Runners.connection_state(%Runner{disabled_at: now}) == :disabled
      assert Runners.connection_state(%Runner{online?: false, last_connected_at: nil}) == :pending

      assert Runners.connection_state(%Runner{online?: false, last_connected_at: now}) ==
               :offline

      # disabled wins over a still-live socket
      assert Runners.connection_state(%Runner{online?: true, disabled_at: now}) == :disabled
    end

    # there is NO heartbeat-age `:stale` state by design.
    # Liveness is enforced only at the socket (the 90s heartbeat-timeout watcher),
    # never re-derived from `last_heartbeat_at`: an `online?` runner reads :online
    # no matter how old its last heartbeat looks. The binary stays honest because
    # the socket would already have closed a genuinely silent runner to :offline.
    test "stays :online regardless of last_heartbeat_at age (no :stale)" do
      ancient = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert Runners.connection_state(%Runner{online?: true, last_heartbeat_at: ancient}) ==
               :online

      # A nil heartbeat on a live socket is still :online, not a derived stale state.
      assert Runners.connection_state(%Runner{online?: true, last_heartbeat_at: nil}) == :online
    end
  end

  describe "runner_scopes_for_membership/1" do
    setup do
      {account, _user, subject} = account_with_owner_subject()
      %{account: account, subject: subject}
    end

    test "returns the membership's scope rows, ordered by type then value", %{
      account: account,
      subject: subject
    } do
      member =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      # scope_type is supplied as a STRING (the team LV passes "group"/"runner");
      # Ecto.Enum stores it and reads it back as an atom.
      :ok =
        put_scopes(member, [{"runner", "rid-2"}, {"group", "web"}, {"runner", "rid-1"}], subject)

      tuples =
        Runners.runner_scopes_for_membership(member.id)
        |> Enum.map(&{&1.scope_type, &1.scope_value})

      # ordered_by_type_and_value: groups before runners, then by value.
      assert tuples == [{:group, "web"}, {:runner, "rid-1"}, {:runner, "rid-2"}]
    end

    test "an empty (all-runners) membership has no scope rows", %{account: account} do
      member =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert Runners.runner_scopes_for_membership(member.id) == []
    end
  end

  describe "replace_runner_scopes/3" do
    setup do
      {account, _user, subject} = account_with_owner_subject()
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      %{account: account, subject: subject, member: member}
    end

    test "replaces the scope set atomically", %{subject: subject, member: member} do
      # scope_type is a STRING (the team LV passes "group"/"runner"); it reads
      # back as an Ecto.Enum atom.
      assert {:ok, :ok} =
               Runners.replace_runner_scopes(
                 member,
                 [{"group", "web"}, {"runner", "rid-1"}],
                 subject
               )

      tuples =
        Runners.runner_scopes_for_membership(member.id)
        |> Enum.map(&{&1.scope_type, &1.scope_value})

      assert tuples == [{:group, "web"}, {:runner, "rid-1"}]

      # A second replace fully supersedes the first (clear + insert).
      assert {:ok, :ok} = Runners.replace_runner_scopes(member, [{"group", "db"}], subject)

      assert Runners.runner_scopes_for_membership(member.id)
             |> Enum.map(& &1.scope_value) == ["db"]
    end

    test "an empty list clears the set → all-runners", %{subject: subject, member: member} do
      {:ok, :ok} = Runners.replace_runner_scopes(member, [{"group", "web"}], subject)
      assert {:ok, :ok} = Runners.replace_runner_scopes(member, [], subject)

      assert Runners.runner_scopes_for_membership(member.id) == []
    end

    test "an invalid scope tuple is rejected as a changeset (nothing written)", %{
      subject: subject,
      member: member
    } do
      assert {:error, %Ecto.Changeset{}} =
               Runners.replace_runner_scopes(member, [{"group", ""}], subject)

      assert Runners.runner_scopes_for_membership(member.id) == []
    end

    test "writes a membership.runner_scopes_changed audit row", %{
      subject: subject,
      member: member
    } do
      assert {:ok, :ok} = Runners.replace_runner_scopes(member, [{"group", "web"}], subject)

      events = Audit.list_events(subject, page: [limit: 20]) |> elem(1)
      changed = Enum.find(events, &(&1.event_type == "membership.runner_scopes_changed"))
      assert changed != nil
      assert changed.payload["scope_count"] == 1
    end

    test "a viewer (no manage_team) is refused", %{account: account, member: member} do
      assert {:error, :unauthorized} =
               Runners.replace_runner_scopes(
                 member,
                 [{"group", "web"}],
                 viewer_subject_for(account)
               )
    end

    test "won't touch a membership in another account (cross-account → :unauthorized)", %{
      member: member
    } do
      {_account_b, _ub, owner_b} = account_with_owner_subject()

      assert {:error, :unauthorized} =
               Runners.replace_runner_scopes(member, [{"group", "web"}], owner_b)
    end
  end

  describe "runner_scopes_for_membership_ids/1" do
    test "batches scopes into %{membership_id => [scope]} for several memberships" do
      {account, _user, subject} = account_with_owner_subject()
      m1 = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
      m2 = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      :ok = put_scopes(m1, [{"group", "web"}], subject)
      :ok = put_scopes(m2, [{"runner", "rid-9"}], subject)

      batched = Runners.runner_scopes_for_membership_ids([m1.id, m2.id])

      assert batched |> Map.fetch!(m1.id) |> Enum.map(& &1.scope_value) == ["web"]
      assert batched |> Map.fetch!(m2.id) |> Enum.map(& &1.scope_value) == ["rid-9"]
    end

    test "an empty id list short-circuits to an empty map" do
      assert Runners.runner_scopes_for_membership_ids([]) == %{}
      assert Runners.runner_scopes_for_membership_ids([nil]) == %{}
    end
  end

  describe "runner_in_scope?/2" do
    test "an empty scope list means all runners are in scope" do
      runner = Fixtures.Runners.create_runner(group: "web", connected?: false)
      assert Runners.runner_in_scope?(runner, [])
    end

    test "a nil membership is always in scope (callers do their own auth)" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      assert Runners.runner_in_scope?(runner, nil)
    end

    test "matches on the runner's id OR its group; otherwise false" do
      runner = %{id: "rid-1", group: "web"}

      assert Runners.runner_in_scope?(runner, [
               %Runners.UserRunnerScope{scope_type: :runner, scope_value: "rid-1"}
             ])

      assert Runners.runner_in_scope?(runner, [
               %Runners.UserRunnerScope{scope_type: :group, scope_value: "web"}
             ])

      refute Runners.runner_in_scope?(runner, [
               %Runners.UserRunnerScope{scope_type: :group, scope_value: "db"}
             ])
    end

    test "resolves a membership's own scopes — out-of-scope runner is false" do
      {account, _user, subject} = account_with_owner_subject()
      member = Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      in_scope =
        Fixtures.Runners.create_runner(account_id: account.id, group: "web", connected?: false)

      out_scope =
        Fixtures.Runners.create_runner(account_id: account.id, group: "db", connected?: false)

      :ok = put_scopes(member, [{"group", "web"}], subject)

      assert Runners.runner_in_scope?(in_scope, member)
      refute Runners.runner_in_scope?(out_scope, member)
    end
  end

  describe "list_auth_keys/2" do
    setup do
      {account, _user, subject} = account_with_owner_subject()
      %{account: account, subject: subject}
    end

    test "lists operator-visible keys, hiding auto-unused install keys", %{subject: subject} do
      {:ok, _, _} = Runners.mint_install_key(subject)
      {:ok, _, manual} = Runners.create_auth_key(%{reusable: true}, subject)

      # Both rows exist; only the manually-issued one is operator-visible.
      assert Repo.aggregate(AuthKey, :count) == 2
      assert {:ok, [%AuthKey{id: id}], _} = Runners.list_auth_keys(subject)
      assert id == manual.id
    end

    test "the status filter hides or shows revoked keys", %{subject: subject} do
      {:ok, _, active} = Runners.create_auth_key(%{reusable: true}, subject)
      {:ok, _, revoked} = Runners.create_auth_key(%{reusable: true}, subject)
      {:ok, _} = Runners.revoke_auth_key(revoked, subject)

      # No status filter → both keys.
      assert {:ok, both, _} = Runners.list_auth_keys(subject)
      assert length(both) == 2

      # status=active → only the live key.
      assert {:ok, [%AuthKey{id: id}], _} =
               Runners.list_auth_keys(subject, filter: [status: ["active"]])

      assert id == active.id

      # status=revoked → only the revoked key.
      assert {:ok, [%AuthKey{id: id}], _} =
               Runners.list_auth_keys(subject, filter: [status: ["revoked"]])

      assert id == revoked.id
    end

    test "is account-scoped — another account's keys don't leak in", %{subject: subject} do
      {:ok, _, _mine} = Runners.create_auth_key(%{reusable: true}, subject)
      {_other, _u, other_subject} = account_with_owner_subject()
      {:ok, _, _theirs} = Runners.create_auth_key(%{reusable: true}, other_subject)

      assert {:ok, [_one], _} = Runners.list_auth_keys(subject)
    end

    test "a viewer (no manage_auth_keys) is refused", %{account: account} do
      assert {:error, :unauthorized} = Runners.list_auth_keys(viewer_subject_for(account))
    end
  end

  describe "change_auth_key/1" do
    test "builds a valid form changeset from the operator-facing fields (no DB write)" do
      changeset = Runners.change_auth_key(%{"description" => "for dev"})

      assert %Ecto.Changeset{} = changeset
      assert Ecto.Changeset.get_change(changeset, :description) == "for dev"
      # It's a pure builder — no key was minted.
      refute Repo.exists?(AuthKey.Query.all())
    end

    test "surfaces a validation error for the inline form (max_uses must be > 0)" do
      changeset = Runners.change_auth_key(%{"max_uses" => 0})

      refute changeset.valid?
      assert changeset.errors[:max_uses]
    end
  end

  describe "create_auth_key/2" do
    setup do
      {account, user, subject} = account_with_owner_subject()
      %{account: account, user: user, subject: subject}
    end

    test "returns a raw secret + persists the hash with a prefix", %{
      account: account,
      user: user,
      subject: subject
    } do
      assert {:ok, raw, %AuthKey{} = key} =
               Runners.create_auth_key(%{description: "for dev"}, subject)

      assert String.starts_with?(raw, "emkey-auth-")
      assert key.account_id == account.id
      assert key.created_by_id == user.id
      assert is_binary(key.key_hash)
      assert key.description == "for dev"
    end

    test "rejects max_uses: 0 at the write path, not just the form", %{subject: subject} do
      # max_uses 0 mints a key that's dead on arrival; create/5 must enforce
      # the same `> 0` guard the editor form does, not rely on it.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Runners.create_auth_key(%{description: "dead", max_uses: 0}, subject)

      assert %{max_uses: ["must be greater than 0"]} = errors_on(changeset)
    end

    test "a viewer (no manage_auth_keys) is refused", %{account: account} do
      assert {:error, :unauthorized} =
               Runners.create_auth_key(%{reusable: true}, viewer_subject_for(account))
    end
  end

  describe "subscribe_connections/1" do
    test "the subscriber receives this account's presence diffs" do
      account = Fixtures.Accounts.create_account()
      :ok = Runners.subscribe_connections(account.id)

      # Tracking a runner pushes a presence_diff on the topic just joined.
      _ = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}
    end

    test "a subscriber to account A does not receive account B's presence diffs" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      :ok = Runners.subscribe_connections(account_a.id)

      _ = Fixtures.Runners.create_runner(account_id: account_b.id, connected?: true)
      refute_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}
    end
  end

  describe "subscribe_account_auth_keys/1" do
    test "the subscriber receives the account's auth-key list changes" do
      {account, _user, subject} = account_with_owner_subject()
      :ok = Runners.subscribe_account_auth_keys(account.id)

      {:ok, _raw, key} = Runners.create_auth_key(%{reusable: true}, subject)
      assert_receive {:list_changed, :auth_key, "auth_key.created", key_id}
      assert key_id == key.id
    end

    test "a subscriber to account A does not receive account B's auth-key changes" do
      {_account_a, _ua, _sa} = account_with_owner_subject()
      account_a = Fixtures.Accounts.create_account()
      {_account_b, _ub, subject_b} = account_with_owner_subject()
      :ok = Runners.subscribe_account_auth_keys(account_a.id)

      {:ok, _raw, _key} = Runners.create_auth_key(%{reusable: true}, subject_b)
      refute_receive {:list_changed, :auth_key, _event, _id}
    end
  end

  describe "subscribe_runner_transport/1" do
    test "the subscriber receives this runner's cloud→runner deliveries" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      :ok = Runners.subscribe_runner_transport(runner)

      Runners.deliver_to_runner(runner.account_id, runner.id, %{"hello" => "runner"})
      assert_receive {:cloud_to_runner, %{"hello" => "runner"}}
    end

    test "a subscriber to runner A does not receive runner B's deliveries" do
      account = Fixtures.Accounts.create_account()
      runner_a = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      runner_b = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      :ok = Runners.subscribe_runner_transport(runner_a)

      Runners.deliver_to_runner(account.id, runner_b.id, %{"only" => "b"})
      refute_receive {:cloud_to_runner, _msg}
    end
  end

  describe "deliver_to_runner/3" do
    test "pushes an envelope onto the runner's transport topic" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      :ok = Runners.subscribe_runner_transport(runner)

      assert :ok = Runners.deliver_to_runner(runner.account_id, runner.id, %{"cmd" => "dispatch"})
      assert_receive {:cloud_to_runner, %{"cmd" => "dispatch"}}
    end

    test "the topic carries the account id — a wrong account never reaches the socket" do
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      :ok = Runners.subscribe_runner_transport(runner)

      # Same runner id, wrong account → different topic → the subscriber hears nothing.
      Runners.deliver_to_runner(other_account.id, runner.id, %{"cmd" => "x"})
      refute_receive {:cloud_to_runner, _msg}
    end
  end

  describe "mint_install_key/2" do
    setup do
      {_account, _user, subject} = account_with_owner_subject()
      %{subject: subject}
    end

    test "stores an auto_generated_at timestamp", %{subject: subject} do
      assert {:ok, raw, %AuthKey{} = key} = Runners.mint_install_key(subject)
      assert String.starts_with?(raw, "emkey-auth-")
      assert key.auto_generated_at != nil
      assert is_nil(key.last_used_at)
      assert AuthKey.auto_unused?(key)
    end

    test "ring eviction caps the auto-unused set at the configured size", %{subject: subject} do
      # Tiny cap so the test runs fast. Bypass grace by making it 0 so
      # the eviction query trims the moment we exceed the cap.
      for _ <- 1..5 do
        {:ok, _, _} = Runners.mint_install_key(subject, ring_cap: 3, eviction_grace_seconds: 0)
      end

      assert Repo.aggregate(AuthKey, :count) == 3
    end

    test "grace window protects fresh keys from eviction even past cap", %{subject: subject} do
      # cap=2, but grace=60s means a burst of 5 mints in the same
      # second all survive (none are older than the grace floor).
      for _ <- 1..5 do
        {:ok, _, _} = Runners.mint_install_key(subject, ring_cap: 2, eviction_grace_seconds: 60)
      end

      assert Repo.aggregate(AuthKey, :count) == 5
    end

    test "does NOT touch other accounts' keys", %{subject: subject} do
      {_other, _other_user, other_subject} = account_with_owner_subject()

      {:ok, _, other_key} = Runners.mint_install_key(other_subject)

      # Saturate this account's ring.
      for _ <- 1..10 do
        {:ok, _, _} = Runners.mint_install_key(subject, ring_cap: 2, eviction_grace_seconds: 0)
      end

      # `other`'s key is untouched.
      assert AuthKey.Query.all() |> AuthKey.Query.by_id(other_key.id) |> Repo.peek() != nil
    end

    test "a viewer (no issue_install_key) is refused" do
      account = Fixtures.Accounts.create_account()
      assert {:error, :unauthorized} = Runners.mint_install_key(viewer_subject_for(account))
    end
  end

  describe "revoke_auth_key/2" do
    setup do
      {account, _user, subject} = account_with_owner_subject()
      %{account: account, subject: subject}
    end

    test "stamps revoked_at; the key no longer resolves for registration", %{subject: subject} do
      {:ok, raw, key} = Runners.create_auth_key(%{reusable: true}, subject)

      assert {:ok, %AuthKey{revoked_at: %DateTime{}}} = Runners.revoke_auth_key(key, subject)
      refute Runners.peek_auth_key_by_secret(raw)
    end

    test "revoking an already-revoked key is an idempotent no-op (preserves revoked_at)", %{
      subject: subject
    } do
      {:ok, _raw, key} = Runners.create_auth_key(%{reusable: true}, subject)
      {:ok, revoked} = Runners.revoke_auth_key(key, subject)

      # A second revoke returns the key without re-stamping a fresh timestamp.
      assert {:ok, %AuthKey{} = again} = Runners.revoke_auth_key(revoked, subject)
      assert again.revoked_at == revoked.revoked_at
    end

    test "a viewer (no manage_auth_keys) is refused", %{account: account, subject: owner} do
      {:ok, _raw, key} = Runners.create_auth_key(%{reusable: true}, owner)

      assert {:error, :unauthorized} = Runners.revoke_auth_key(key, viewer_subject_for(account))
    end

    test "won't touch an auth key in another account (cross-account → :not_found)" do
      {_account_a, _ua, owner_a} = account_with_owner_subject()
      {_account_b, _ub, owner_b} = account_with_owner_subject()
      {:ok, _raw, key_a} = Runners.create_auth_key(%{reusable: true}, owner_a)

      assert {:error, :not_found} = Runners.revoke_auth_key(key_a, owner_b)
    end
  end

  describe "peek_auth_key_by_secret/1" do
    setup do
      {_account, _user, subject} = account_with_owner_subject()
      %{subject: subject}
    end

    test "returns the key for a valid secret", %{subject: subject} do
      {:ok, raw, %AuthKey{id: id}} = Runners.create_auth_key(%{reusable: true}, subject)

      assert %AuthKey{id: ^id} = Runners.peek_auth_key_by_secret(raw)
    end

    test "returns nil for a revoked key", %{subject: subject} do
      {:ok, raw, key} = Runners.create_auth_key(%{reusable: true}, subject)
      {:ok, _} = Runners.revoke_auth_key(key, subject)

      refute Runners.peek_auth_key_by_secret(raw)
    end

    test "returns nil for an expired key", %{subject: subject} do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      {:ok, raw, _key} =
        Runners.create_auth_key(%{reusable: true, expires_at: past}, subject)

      refute Runners.peek_auth_key_by_secret(raw)
    end

    test "returns nil for a single-use key after first use", %{subject: subject} do
      {:ok, raw, key} = Runners.create_auth_key(%{reusable: false}, subject)

      # First use bumps usage; second lookup should miss.
      assert %AuthKey{id: id} = Runners.peek_auth_key_by_secret(raw)
      assert id == key.id

      {:ok, _} = key |> AuthKey.Changeset.usage() |> Repo.update()
      refute Runners.peek_auth_key_by_secret(raw)
    end

    test "returns nil for garbage input" do
      refute Runners.peek_auth_key_by_secret("not-a-key")
      refute Runners.peek_auth_key_by_secret("")
    end

    test "round-trips a fixed seed-bootstrap raw secret" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      raw = "emkey-auth-dev-fixed-bootstrap-DO-NOT-USE-IN-PROD"

      key =
        Fixtures.Runners.create_auth_key_with_secret(raw, account.id, user.id, %{reusable: true})

      assert key.key_prefix == String.slice(raw, 0, 27)
      # Presenting the raw secret resolves to the same record — what makes the
      # docker-compose seeder + runner handoff work without an out-of-band copy.
      assert %AuthKey{id: id} = Runners.peek_auth_key_by_secret(raw)
      assert id == key.id
    end
  end

  describe "mint_runner_token/2" do
    test "mints a prefixed raw token + persists its hash, bound to the runner" do
      runner = Fixtures.Runners.create_runner(connected?: false)

      assert {raw, %Token{} = token} = Runners.mint_runner_token(runner)
      assert String.starts_with?(raw, "rnrtok-")
      assert token.runner_id == runner.id
      assert is_binary(token.token_hash)
      # The minted raw token verifies back to this runner.
      assert {:ok, %Token{}, %Runner{id: id}} = Runners.verify_runner_token(raw)
      assert id == runner.id
    end

    test "records the issuing auth-key id when supplied" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {_raw, key} = Fixtures.Runners.create_auth_key(account_id: account.id)

      assert {_raw, %Token{issued_via_key_id: key_id}} = Runners.mint_runner_token(runner, key.id)
      assert key_id == key.id
    end
  end

  describe "verify_runner_token/1" do
    test "returns {:ok, token, runner} for a valid raw token and bumps last_used_at" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      {raw, token} = Runners.mint_runner_token(runner)

      assert {:ok, %Token{}, %Runner{id: id}} = Runners.verify_runner_token(raw)
      assert id == runner.id
      # `verify_runner_token` bumps last_used_at server-side; reload to observe.
      assert %Token{last_used_at: %DateTime{}} = Repo.reload!(token)
    end

    test "returns {:error, :token_invalid} for garbage" do
      assert {:error, :token_invalid} = Runners.verify_runner_token("rnrtok-garbage")
      assert {:error, :token_invalid} = Runners.verify_runner_token("")
    end

    test "returns {:error, :token_invalid} for a disabled runner's token" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {raw, _token} = Runners.mint_runner_token(runner)

      {:ok, _} = Runners.disable_runner(runner, subject)

      assert {:error, :token_invalid} = Runners.verify_runner_token(raw)
    end
  end

  describe "subject_can_manage_runners?/1" do
    test "true for an owner, false for a viewer" do
      {account, _user, owner} = account_with_owner_subject()

      assert Runners.subject_can_manage_runners?(owner)
      refute Runners.subject_can_manage_runners?(viewer_subject_for(account))
    end
  end

  describe "subject_can_manage_auth_keys?/1" do
    test "true for an owner, false for a viewer" do
      {account, _user, owner} = account_with_owner_subject()

      assert Runners.subject_can_manage_auth_keys?(owner)
      refute Runners.subject_can_manage_auth_keys?(viewer_subject_for(account))
    end
  end

  describe "register_via_auth_key/2" do
    test "mints an runner + token on success" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      {raw, _key} =
        Fixtures.Runners.create_auth_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      assert {:ok, %Runner{} = runner, %Token{}, raw_token} =
               Runners.register_via_auth_key(raw, %{
                 hostname: "demo-1",
                 group: "demo",
                 external_id: "ext-#{System.unique_integer([:positive])}"
               })

      assert runner.account_id == account.id
      assert is_binary(raw_token)
      assert String.starts_with?(raw_token, "rnrtok-")
    end

    test "re-registration with the same external_id reuses the runner" do
      # Reconnect: the runner persists + presents a stable external_id, so
      # the same row is reused (and the version is refreshed). This is the
      # path that used to 500 on the (account_id, name) unique index.
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      {raw, _key} =
        Fixtures.Runners.create_auth_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      attrs = %{
        hostname: "cs-429836741138",
        group: "cs-default",
        version: "0.3.1",
        external_id: "stable-ext-id-1"
      }

      assert {:ok, %Runner{id: id1, runner_version: "0.3.1"}, %Token{}, _} =
               Runners.register_via_auth_key(raw, attrs)

      assert {:ok, %Runner{id: id2}, %Token{}, _} =
               Runners.register_via_auth_key(raw, attrs)

      assert id1 == id2
    end

    test "re-registration after a soft-delete creates a fresh runner" do
      # The (account_id, external_id) unique index is partial
      # (WHERE deleted_at IS NULL), so a soft-deleted runner no longer
      # reserves its external_id: the same host re-registers as a brand-new
      # row instead of 500ing on the constraint / re-fetch mismatch.
      {account, user, subject} = account_with_owner_subject()

      {raw, _key} =
        Fixtures.Runners.create_auth_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      attrs = %{hostname: "host-x", group: "g", external_id: "recycled-ext-id"}

      assert {:ok, %Runner{id: id1} = runner1, %Token{}, _} =
               Runners.register_via_auth_key(raw, attrs)

      assert {:ok, %Runner{id: ^id1}} = Runners.delete_runner(runner1, subject)

      assert {:ok, %Runner{id: id2}, %Token{}, _} =
               Runners.register_via_auth_key(raw, attrs)

      refute id1 == id2
    end

    test "a CONNECTED holder keeps its name — a different external_id is rejected" do
      # Names are unique among live runners. An actively connected holder is
      # a real conflict: a different machine reusing the name gets a clean
      # error, never a silent takeover of a working runner.
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      {raw, _key} =
        Fixtures.Runners.create_auth_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      base = %{hostname: "samehost", group: "g"}

      assert {:ok, %Runner{name: "samehost"} = holder, _, _} =
               Runners.register_via_auth_key(raw, Map.put(base, :external_id, "ext-a"))

      {:ok, _} = Runners.connect_runner(holder)

      assert {:error, :runner_name_taken, "samehost"} =
               Runners.register_via_auth_key(raw, Map.put(base, :external_id, "ext-b"))
    end

    test "an OFFLINE holder keeps the name — a conflict is a conflict" do
      # No displacement magic: a live row holding the name, connected or
      # not, conflicts. The operator renames or deletes the holder.
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      {raw, _key} =
        Fixtures.Runners.create_auth_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      base = %{hostname: "samehost", group: "g"}

      assert {:ok, %Runner{id: holder_id, name: "samehost"}, _, _} =
               Runners.register_via_auth_key(raw, Map.put(base, :external_id, "ext-a"))

      assert {:error, :runner_name_taken, "samehost"} =
               Runners.register_via_auth_key(raw, Map.put(base, :external_id, "ext-b"))

      # The holder is untouched.
      assert %Runner{} = Runners.peek_runner_by_id(holder_id)
    end

    test "a taken name frees up once the holding runner is deleted" do
      {account, user, subject} = account_with_owner_subject()

      {raw, _key} =
        Fixtures.Runners.create_auth_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      base = %{hostname: "samehost", group: "g"}

      assert {:ok, %Runner{} = holder, _, _} =
               Runners.register_via_auth_key(raw, Map.put(base, :external_id, "ext-a"))

      # Connected holders are never displaced — the conflict stands.
      {:ok, holder} = Runners.connect_runner(holder)

      assert {:error, :runner_name_taken, "samehost"} =
               Runners.register_via_auth_key(raw, Map.put(base, :external_id, "ext-b"))

      # Deleting the holder soft-deletes it, freeing the name (partial index).
      {:ok, _} = Runners.delete_runner(holder, subject)

      assert {:ok, %Runner{name: "samehost"}, _, _} =
               Runners.register_via_auth_key(raw, Map.put(base, :external_id, "ext-b"))
    end

    test "registers without an external_id (no crash); re-registering conflicts on the name" do
      # A legacy runner that doesn't send external_id: the server mints a
      # fresh UUID, so the first register succeeds cleanly (no 500). A second
      # register from the same host (same name, still no external_id) gets a
      # fresh identity too — so the taken name is a clean conflict, not a
      # silent takeover.
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      {raw, _key} =
        Fixtures.Runners.create_auth_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      attrs = %{hostname: "no-id-host", group: "g"}

      assert {:ok, %Runner{id: first_id}, _, _} = Runners.register_via_auth_key(raw, attrs)

      assert {:error, :runner_name_taken, "no-id-host"} =
               Runners.register_via_auth_key(raw, attrs)

      assert %Runner{} = Runners.peek_runner_by_id(first_id)
    end

    test "returns :over_limit when the plan cap is exceeded" do
      # `free` plan caps runners at 3.
      account = Fixtures.Accounts.create_account(plan: "free")
      user = Fixtures.Users.create_user()

      _ = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Runners.create_runner(account_id: account.id)

      {raw, _key} =
        Fixtures.Runners.create_auth_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      assert {:error, :over_limit, "free", 3} =
               Runners.register_via_auth_key(raw, %{group: "demo"})
    end

    test "a reconnecting runner at the plan cap still registers (its seat is already counted)" do
      # `free` caps runners at 3. Fill the account to the cap, with one runner
      # registered via a stable external_id so we can reconnect it.
      account = Fixtures.Accounts.create_account(plan: "free")
      user = Fixtures.Users.create_user()

      {raw, _key} =
        Fixtures.Runners.create_auth_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      assert {:ok, %Runner{}, _, _} =
               Runners.register_via_auth_key(raw, %{external_id: "ext-keep", group: "g"})

      _ = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Runners.create_runner(account_id: account.id)

      # Now at 3/3. Re-registering the SAME runner (e.g. it lost its token on a
      # redeploy) must NOT be blocked by its own seat — regression for the
      # limit check running before the reconnect-vs-fresh decision.
      assert {:ok, %Runner{}, _, _} =
               Runners.register_via_auth_key(raw, %{external_id: "ext-keep", group: "g"})

      # ...but a genuinely NEW runner at the cap is still refused.
      assert {:error, :over_limit, "free", 3} =
               Runners.register_via_auth_key(raw, %{external_id: "ext-new", group: "g"})
    end

    test "returns :auth_key_invalid for an unknown raw secret" do
      assert {:error, :auth_key_invalid} =
               Runners.register_via_auth_key("emkey-auth-garbage", %{})
    end

    test "threads the request context onto the runner.registered audit row" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      {_owner_user, _acct, subject} = {user, account, owner_subject_for(account, user)}

      {raw, _key} =
        Fixtures.Runners.create_auth_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      context = %RequestContext{ip_address: "203.0.113.7"}

      assert {:ok, %Runner{}, _, _} =
               Runners.register_via_auth_key(
                 raw,
                 %{hostname: "ctx-host", group: "g", external_id: "ext-ctx"},
                 context
               )

      events = Audit.list_events(subject, page: [limit: 20]) |> elem(1)
      registered = Enum.find(events, &(&1.event_type == "runner.registered"))
      assert registered != nil
      assert registered.ip_address == "203.0.113.7"
    end

    test "single-use key under concurrent attempts: exactly one succeeds" do
      # Guards against the race the atomic-claim defends against: two
      # callers both observe `uses_count = 0` and both try to register.
      # With the old serial "select then update" implementation, both
      # succeeded and we ended up with two runners minted from a single
      # single-use key.
      #
      # `Task.async` inherits the sandbox connection via `$callers`,
      # so the parallel registrations all see the same DB state under
      # async: true. No explicit `Sandbox.allow` needed.
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      {raw, _key} =
        Fixtures.Runners.create_auth_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: false
        )

      results =
        1..8
        |> Enum.map(fn i ->
          Task.async(fn ->
            Runners.register_via_auth_key(raw, %{
              hostname: "demo-#{i}",
              group: "demo",
              # Distinct external_ids so a stray double-success would
              # produce two distinct runner rows, surfacing the bug
              # rather than silently merging.
              external_id: "ext-#{i}-#{System.unique_integer([:positive])}"
            })
          end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      successes = Enum.count(results, &match?({:ok, _, _, _}, &1))
      failures = Enum.count(results, &match?({:error, :auth_key_invalid}, &1))

      assert successes == 1, "expected exactly 1 success, got #{successes}: #{inspect(results)}"
      assert failures == 7, "expected 7 :auth_key_invalid failures, got #{failures}"
    end

    test "promotes an auto-generated install key to permanent on first use" do
      {_account, _user, subject} = account_with_owner_subject()
      {:ok, raw, key} = Runners.mint_install_key(subject)
      assert AuthKey.auto_unused?(key)

      assert {:ok, %Runner{}, _, _} =
               Runners.register_via_auth_key(raw, %{
                 hostname: "demo-1",
                 group: "demo",
                 external_id: "ext-#{System.unique_integer([:positive])}"
               })

      # auto_generated_at cleared, last_used_at set, key now visible.
      reloaded = AuthKey.Query.all() |> AuthKey.Query.by_id(key.id) |> Repo.fetch!(AuthKey.Query)
      assert is_nil(reloaded.auto_generated_at)
      assert reloaded.last_used_at != nil
      assert {:ok, [%AuthKey{id: id}], _} = Runners.list_auth_keys(subject)
      assert id == key.id
    end

    test "emits an auth_key.bound audit event with auto: true on auto-key bind" do
      {_account, _user, subject} = account_with_owner_subject()
      {:ok, raw, _key} = Runners.mint_install_key(subject)

      {:ok, _runner, _token, _raw_token} =
        Runners.register_via_auth_key(raw, %{
          hostname: "demo",
          group: "demo",
          external_id: "ext-#{System.unique_integer([:positive])}"
        })

      events = Audit.list_events(subject, page: [limit: 50]) |> elem(1)
      bound = Enum.find(events, &(&1.event_type == "auth_key.bound"))
      assert bound != nil
      assert bound.payload["auto"] == true
    end
  end

  # The plan-limit + billing-seat behavior that register/disable/enable lean on
  # — Billing owns check_limit, but these prove the Runners write paths honor it.
  describe "plan-limit runner count (Billing.check_limit/2)" do
    setup do
      {account, _user, subject} = account_with_owner_subject()
      %{account: account, subject: subject}
    end

    test "deleted runners don't count toward the limit", %{account: account, subject: subject} do
      r1 = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      assert {:error, :over_limit, "free", 3} = Billing.check_limit(account, :runners)

      {:ok, _} = Runners.delete_runner(r1, subject)

      assert :ok = Billing.check_limit(account, :runners)
      assert {:ok, %{runner_count: 2}} = Billing.billing_summary(account, subject)
    end

    test "disabled runners don't count toward the limit", %{account: account, subject: subject} do
      r1 = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      assert {:error, :over_limit, "free", 3} = Billing.check_limit(account, :runners)

      {:ok, _} = Runners.disable_runner(r1, subject)
      assert :ok = Billing.check_limit(account, :runners)
    end

    test "a past_due account keeps full plan limits — status never gates registration" do
      # account_plan/1 is status-agnostic, so a Team account whose subscription
      # lapsed to past_due still resolves to the Team cap (100) and registers a
      # runner under it. Billing status is advisory (banners), never an entitlement
      # gate — register_via_auth_key only blocks on the runner cap.
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(account, "team", status: "past_due")
      user = Fixtures.Users.create_user()

      assert Billing.account_plan(account) == "team"
      # Two runners on a Team plan is well under the cap → check_limit is :ok.
      _ = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Runners.create_runner(account_id: account.id)
      assert :ok = Billing.check_limit(account, :runners)

      {raw, _key} =
        Fixtures.Runners.create_auth_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      assert {:ok, %Runner{}, _, _} =
               Runners.register_via_auth_key(raw, %{external_id: "ext-pastdue", group: "g"})
    end
  end

  describe "Authorizer.for_subject runner-scoping" do
    test "a runner subject sees only its own runner row, not its account peers" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _peer = Fixtures.Runners.create_runner(account_id: account.id)

      runner_subject = Subject.for_runner(runner, account)

      ids =
        Runner.Query.all()
        |> Runners.Authorizer.for_subject(runner_subject)
        |> Repo.all()
        |> Enum.map(& &1.id)

      # Cross-runner visibility within an account is intentionally impossible.
      assert ids == [runner.id]
    end

    test "an account-less / actor-less subject leaves the query unscoped (fallback)" do
      query = Runner.Query.all()
      assert Runners.Authorizer.for_subject(query, %Subject{}) == query
    end
  end

  # Stamp a runner's durable connection-record columns directly — `register/0`
  # leaves a fresh runner never-connected, so the connection-state tests set them.
  defp put_connection(runner, fields),
    do: runner |> Ecto.Changeset.change(fields) |> Repo.update!()

  defp viewer_subject_for(account) do
    viewer = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

    Fixtures.Subjects.subject_for(viewer, account, role: :viewer)
  end

  defp owner_subject_for(account, user) do
    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    Fixtures.Subjects.subject_for(user, account, role: :owner)
  end

  # Write a membership's runner scopes through the real API so the
  # scope-reader tests don't reach into UserRunnerScope internals.
  defp put_scopes(membership, scopes, subject) do
    {:ok, :ok} = Runners.replace_runner_scopes(membership, scopes, subject)
    :ok
  end
end
