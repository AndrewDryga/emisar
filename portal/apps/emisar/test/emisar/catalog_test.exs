defmodule Emisar.CatalogTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Audit, Catalog}
  alias Emisar.Catalog.{PackVersion, RunnerAction}

  defp state_payload(opts) do
    %{
      "hostname" => Keyword.get(opts, :hostname, "host-1"),
      "version" => Keyword.get(opts, :version, "0.1.0"),
      "labels" => Keyword.get(opts, :labels, %{"env" => "test"}),
      "packs" => Keyword.get(opts, :packs, %{}),
      "actions" => Keyword.get(opts, :actions, [])
    }
  end

  defp action(id, opts \\ []) do
    %{
      "id" => id,
      "pack_id" => Keyword.get(opts, :pack_id, "demo"),
      "title" => Keyword.get(opts, :title, id),
      "kind" => Keyword.get(opts, :kind, "exec"),
      "risk" => Keyword.get(opts, :risk, "low"),
      "description" => Keyword.get(opts, :description, "test"),
      "args" => Keyword.get(opts, :args, [])
    }
  end

  describe "observe_state/2 — packs" do
    test "upserts pack_versions" do
      runner = runner_fixture()
      account = Emisar.Repo.preload(runner, :account).account
      subject = subject_for(user_fixture(), account, role: :owner)

      # No library baseline for linux-core@1.0 (we ship 0.3.0), so this
      # lands as pending with the advertised hash sitting in pending_hash.
      payload =
        state_payload(packs: %{"linux-core" => %{"version" => "1.0", "hash" => "abc"}})

      assert {:ok, _runner} = Catalog.observe_state(runner, payload)

      assert {:ok,
              [
                %PackVersion{
                  pack_id: "linux-core",
                  version: "1.0",
                  hash: nil,
                  pending_hash: "abc",
                  trust_state: :pending
                }
              ], _meta} = Catalog.list_pack_versions(subject)

      # Idempotent — same payload should not duplicate.
      assert {:ok, _runner} = Catalog.observe_state(runner, payload)
      assert {:ok, [_], _meta} = Catalog.list_pack_versions(subject)
    end

    test "commits the runner-row facts even when the catalog sync raises" do
      runner = runner_fixture()

      # A pack whose info is a string (not a map) makes the pack sync raise
      # mid-transaction. The runner-row facts (version) are committed first
      # in their own transaction, so they must persist anyway — and the
      # socket must not crash (observe_state still returns {:ok, _}).
      payload = state_payload(version: "9.9.9", packs: %{"bad" => "not-a-map"})

      assert {:ok, _runner} = Catalog.observe_state(runner, payload)

      reloaded = Emisar.Runners.peek_runner_by_id(runner.id)
      assert reloaded.runner_version == "9.9.9"
    end

    test "an apply_state error does not crash observe_state; the catalog still syncs" do
      # Regression: `apply_state` ends in `Repo.update` and can return
      # `{:error, changeset}` from a bad field in untrusted runner JSON (here
      # a string where `labels` expects a map → cast error). It used to be a
      # hard `{:ok, _} = apply_state(...)` match above the try/rescue, so the
      # MatchError killed the runner socket → reconnect loop → same crash.
      # observe_state must keep the existing runner struct, NOT raise, and
      # still upsert the packs/actions in the same advertisement.
      runner = runner_fixture()
      account = Emisar.Repo.preload(runner, :account).account
      subject = subject_for(user_fixture(), account, role: :owner)

      payload =
        state_payload(
          labels: "not-a-map",
          actions: [action("linux.uptime")]
        )

      assert {:ok, returned} = Catalog.observe_state(runner, payload)
      assert returned.id == runner.id

      # The catalog sync below the failed row-update still ran.
      assert {:ok, [%RunnerAction{action_id: "linux.uptime"}], _} =
               Catalog.list_actions_for_runner(runner.id, subject)
    end
  end

  describe "count_pending_pack_versions/1" do
    test "counts pending versions for the account and never another account's" do
      {account, subject} = account_with_owner()
      runner = runner_fixture(account_id: account.id)

      # No shipped baseline for these versions → they land pending.
      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(
            packs: %{
              "linux-core" => %{"version" => "9.9.9", "hash" => "h1"},
              "redis" => %{"version" => "9.9.9", "hash" => "h2"}
            }
          )
        )

      assert Catalog.count_pending_pack_versions(subject) == 2

      # A second account's pending pack must not leak into the first's count.
      {other_account, other_subject} = account_with_owner()
      other_runner = runner_fixture(account_id: other_account.id)

      {:ok, _} =
        Catalog.observe_state(
          other_runner,
          state_payload(packs: %{"redis" => %{"version" => "9.9.9", "hash" => "h3"}})
        )

      assert Catalog.count_pending_pack_versions(subject) == 2
      assert Catalog.count_pending_pack_versions(other_subject) == 1
    end
  end

  describe "list_all_actions_for_account/1" do
    test "returns the COMPLETE catalog — no pagination cap — scoped to the account" do
      {account, subject} = account_with_owner()
      runner = runner_fixture(account_id: account.id)

      # 40 actions — past the paginator's 35-row default page.
      advertised = for n <- 1..40, do: action("pack.act_#{n}")
      {:ok, _} = Catalog.observe_state(runner, state_payload(actions: advertised))

      {:ok, all} = Catalog.list_all_actions_for_account(subject)
      assert length(all) == 40

      # The UI reader is deliberately left paginated.
      {:ok, paged, _meta} = Catalog.list_actions_for_account(subject)
      assert length(paged) == 35

      # Another account sees none of them.
      {_account, other_subject} = account_with_owner()
      assert {:ok, []} = Catalog.list_all_actions_for_account(other_subject)
    end
  end

  describe "list_actions_for_account/2 keyset pagination" do
    test "a multi-page walk returns every row once, in order, when action_id ties" do
      {account, subject} = account_with_owner()

      # 6 runners each advertise the SAME action_id → 6 rows tied on the primary
      # sort key, so paging leans on the last_seen_at + id cursor tail. A cursor
      # that disagreed with the ORDER BY would skip or duplicate tied rows.
      for _ <- 1..6 do
        runner = runner_fixture(account_id: account.id)
        {:ok, _} = Catalog.observe_state(runner, state_payload(actions: [action("shared.act")]))
      end

      {:ok, all, _} = Catalog.list_actions_for_account(subject)
      assert length(all) == 6
      reference_order = Enum.map(all, & &1.id)

      walked = walk_pages(&Catalog.list_actions_for_account(subject, &1), 2)
      assert Enum.map(walked, & &1.id) == reference_order
    end
  end

  describe "list_pack_actions/3" do
    test "returns the distinct actions a pack version advertises, scoped to the account" do
      {account, subject} = account_with_owner()
      runner = runner_fixture(account_id: account.id)

      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(
            packs: %{"acme" => %{"version" => "2.0", "hash" => "h"}},
            actions: [
              action("acme.reload", pack_id: "acme", risk: "high"),
              action("acme.status", pack_id: "acme", risk: "low")
            ]
          )
        )

      assert {:ok, actions} = Catalog.list_pack_actions("acme", "2.0", subject)
      # Ordered by action_id, one row per action (deduped across runners).
      assert Enum.map(actions, & &1.action_id) == ["acme.reload", "acme.status"]
      assert Enum.map(actions, & &1.risk) == [:high, :low]

      # Another account sees none of this account's pack actions.
      {_account, other_subject} = account_with_owner()
      assert {:ok, []} = Catalog.list_pack_actions("acme", "2.0", other_subject)
    end
  end

  describe "pack-trust PubSub" do
    test "broadcasts when pending appears and is resolved, but not on a no-op observe" do
      {account, subject} = account_with_owner()
      runner = runner_fixture(account_id: account.id)
      account_id = account.id
      Emisar.Catalog.subscribe_account_packs(account_id)

      # New custom pack (no shipped baseline) → lands pending → broadcast.
      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom-pack" => %{"version" => "1.0", "hash" => "h1"}})
        )

      assert_receive {:pack_trust_changed, ^account_id}

      # Re-advertising the same pending hash changes nothing → silence.
      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom-pack" => %{"version" => "1.0", "hash" => "h1"}})
        )

      refute_receive {:pack_trust_changed, _}

      # Resolving it (Trust) → broadcast again.
      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      {:ok, _} = Catalog.trust_pack_version(pack_version.id, subject)
      assert_receive {:pack_trust_changed, ^account_id}
    end
  end

  defp account_with_owner do
    account = account_fixture()
    user = user_fixture()
    _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
    {account, subject_for(user, account, role: :owner)}
  end

  describe "observe_state/2 — actions" do
    test "upserts runner_actions" do
      runner = runner_fixture()
      account = Emisar.Repo.preload(runner, :account).account
      subject = subject_for(user_fixture(), account, role: :owner)

      payload =
        state_payload(actions: [action("linux.uptime"), action("linux.df", risk: "medium")])

      assert {:ok, _runner} = Catalog.observe_state(runner, payload)

      {:ok, actions, _} = Catalog.list_actions_for_runner(runner.id, subject)
      assert length(actions) == 2
      assert Enum.any?(actions, &(&1.action_id == "linux.uptime" and &1.risk == :low))
      assert Enum.any?(actions, &(&1.action_id == "linux.df" and &1.risk == :medium))
    end

    test "prunes actions no longer advertised" do
      runner = runner_fixture()
      account = Emisar.Repo.preload(runner, :account).account
      subject = subject_for(user_fixture(), account, role: :owner)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(actions: [action("a"), action("b"), action("c")])
        )

      assert {:ok, actions, _} = Catalog.list_actions_for_runner(runner.id, subject)
      assert length(actions) == 3

      _ = Catalog.observe_state(runner, state_payload(actions: [action("a")]))

      assert {:ok, [%RunnerAction{action_id: "a"}], _} =
               Catalog.list_actions_for_runner(runner.id, subject)
    end

    test "updates the runner row's hostname/labels/version" do
      runner = runner_fixture()

      _ =
        Catalog.observe_state(
          runner,
          state_payload(hostname: "new-host", version: "0.2.0", labels: %{"env" => "prod"})
        )

      reloaded = Repo.reload!(runner)
      assert reloaded.hostname == "new-host"
      assert reloaded.runner_version == "0.2.0"
      assert reloaded.labels == %{"env" => "prod"}
    end

    # closes ENG-004-T05 — a descriptor naming a pack_id NOT in the packs map
    # gets pack_version: nil defensively (vs. raising), and the row still upserts
    # so one missing pack reference doesn't drop the action from the catalog.
    test "an action referencing an unknown pack_id upserts with pack_version nil" do
      runner = runner_fixture()
      account = Emisar.Repo.preload(runner, :account).account
      subject = subject_for(user_fixture(), account, role: :owner)

      # The action's pack_id ("absent") is not a key in the (empty) packs map.
      payload = state_payload(actions: [action("orphan.do", pack_id: "absent")])

      assert {:ok, _runner} = Catalog.observe_state(runner, payload)

      assert {:ok, [%RunnerAction{action_id: "orphan.do", pack_version: nil}], _} =
               Catalog.list_actions_for_runner(runner.id, subject)
    end
  end

  describe "observe_state/2 — runner_id variant" do
    test "looks up the runner by id" do
      runner = runner_fixture()
      account = Emisar.Repo.preload(runner, :account).account
      subject = subject_for(user_fixture(), account, role: :owner)

      assert {:ok, _runner} =
               Catalog.observe_state(runner.id, state_payload(actions: [action("a")]))

      assert {:ok, [%RunnerAction{action_id: "a"}], _} =
               Catalog.list_actions_for_runner(runner.id, subject)
    end

    test "returns {:error, :unknown_runner} for an unknown id" do
      assert {:error, :unknown_runner} = Catalog.observe_state(Ecto.UUID.generate(), %{})
    end
  end

  describe "trust pinning" do
    test "unknown pack first sight → pending, awaits operator approval" do
      runner = runner_fixture()
      account = Emisar.Repo.preload(runner, :account).account
      subject = subject_for(user_fixture(), account, role: :owner)

      payload =
        state_payload(
          packs: %{"my-custom-pack" => %{"version" => "9.9.9", "hash" => "sha256:custom"}}
        )

      assert {:ok, _} = Catalog.observe_state(runner, payload)

      assert {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert pack_version.trust_state == :pending
      assert pack_version.hash == nil
      assert pack_version.pending_hash == "sha256:custom"
    end

    test "custom pack: re-advertising the same pending hash is a touch (no drift event)" do
      runner = runner_fixture()
      account = Emisar.Repo.preload(runner, :account).account
      subject = subject_for(user_fixture(), account, role: :owner)

      payload =
        state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:H1"}})

      assert {:ok, _} = Catalog.observe_state(runner, payload)
      assert {:ok, _} = Catalog.observe_state(runner, payload)

      assert {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert pack_version.trust_state == :pending
      assert pack_version.pending_hash == "sha256:H1"
    end

    test "hash change after operator-trust → pending again" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      assert {:ok, _} =
               Catalog.observe_state(
                 runner,
                 state_payload(packs: %{"x" => %{"version" => "1.0", "hash" => "sha256:H1"}})
               )

      # Custom pack lands pending — operator approves it before the
      # drift scenario is meaningful.
      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.trust_pack_version(pack_version.id, subject)

      assert {:ok, _} =
               Catalog.observe_state(
                 runner,
                 state_payload(packs: %{"x" => %{"version" => "1.0", "hash" => "sha256:H2"}})
               )

      assert {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert pack_version.trust_state == :pending
      assert pack_version.hash == "sha256:H1"
      assert pack_version.pending_hash == "sha256:H2"
    end

    test "concurrent first-sight from two runners → no crash, one row" do
      # Regression: two runners advertising the same pack/version at
      # the same time would both peek nil and then race to insert,
      # crashing the loser on a unique-violation Changeset. With the
      # on_conflict: :nothing fix the loser quietly falls through to
      # the maybe_mark_pending path.
      account = account_fixture()
      runner_a = runner_fixture(account_id: account.id)
      runner_b = runner_fixture(account_id: account.id)
      subject = subject_for(user_fixture(), account, role: :owner)

      # Use a pack id we know has NO library baseline so the TOFU path
      # is exercised (baseline-match would auto-pin without testing the
      # contended insert path).
      payload =
        state_payload(
          packs: %{"raceduck-custom-pack" => %{"version" => "0.3.0", "hash" => "sha256:RACE"}}
        )

      tasks =
        Task.async_stream(
          [runner_a, runner_b],
          &Catalog.observe_state(&1, payload),
          max_concurrency: 2,
          ordered: false
        )

      results = tasks |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &match?({:ok, _}, &1)),
             "one of the concurrent observers crashed: #{inspect(results)}"

      assert {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert pack_version.pack_id == "raceduck-custom-pack"
      assert pack_version.version == "0.3.0"
      # Custom pack — no library baseline, so it lands pending and
      # awaits operator approval. The pending_hash is the bytes both
      # racing runners advertised.
      assert pack_version.trust_state == :pending
      assert pack_version.pending_hash == "sha256:RACE"
      assert pack_version.hash == nil
    end

    test "advertising the trusted hash again after approval → no-op (just touches last_seen)" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      payload =
        state_payload(packs: %{"x" => %{"version" => "1.0", "hash" => "sha256:H1"}})

      assert {:ok, _} = Catalog.observe_state(runner, payload)
      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.trust_pack_version(pack_version.id, subject)
      assert {:ok, _} = Catalog.observe_state(runner, payload)

      assert {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert pack_version.trust_state == :trusted
    end
  end

  describe "catalog reads" do
    test "fetch_pack_version_by_id scopes to the subject's account" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:X"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)

      assert {:ok, %{id: id}} = Catalog.fetch_pack_version_by_id(pack_version.id, subject)
      assert id == pack_version.id
      assert {:error, :not_found} = Catalog.fetch_pack_version_by_id("not-a-uuid", subject)

      {_user_b, _account_b, subject_b} = owner_subject_fixture()
      assert {:error, :not_found} = Catalog.fetch_pack_version_by_id(pack_version.id, subject_b)
    end

    test "check_pack_trusted returns the trusted hash to snapshot, never the pending one" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(
            packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:NEW"}},
            actions: [%{"id" => "p.do", "pack_id" => "p", "title" => "Do"}]
          )
        )

      {:ok, action} = Catalog.fetch_action_for_account("p.do", runner.id, account.id)

      # Custom pack, never trusted → no hash to snapshot (untrusted).
      assert {:error, :pack_untrusted, _} = Catalog.check_pack_trusted(action)

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      {:ok, _} = Catalog.trust_pack_version(pack_version.id, subject)

      assert {:ok, "sha256:NEW"} = Catalog.check_pack_trusted(action)
    end

    test "fetch_action_by_id scopes to the subject's account and rejects junk ids" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)
      _ = action_fixture(runner: runner, action_id: "linux.uptime")

      assert {:ok, action} = Catalog.fetch_action_by_id("linux.uptime", runner.id, subject)
      assert action.account_id == account.id

      assert {:error, :not_found} = Catalog.fetch_action_by_id("linux.uptime", "junk", subject)

      {_user_b, _account_b, subject_b} = owner_subject_fixture()

      assert {:error, :not_found} =
               Catalog.fetch_action_by_id("linux.uptime", runner.id, subject_b)
    end

    # closes ENG-005-T06 — fail-CLOSED on a MISSING pin row. `runner_actions`
    # reference (pack_id, version) by string with no FK, so an action carrying a
    # version that has no pack_versions pin row must read as untrusted (:no_pin),
    # never fall open to trusted (the old design deleted the row on reject).
    test "check_pack_trusted fails closed with :no_pin when no pin row exists" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

      # A versioned action whose (pack_id, version) was never pinned — e.g. its
      # pack pin row was reaped while the action descriptor lingered.
      action = %RunnerAction{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "ghost.do",
        pack_id: "ghost",
        pack_version: "1.0"
      }

      assert {:error, :pack_untrusted, :no_pin} = Catalog.check_pack_trusted(action)
    end
  end

  describe "trust_pack_version / reject_pack_version" do
    test "trust adopts pending_hash as the trusted hash" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:OLD"}})
        )

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:NEW"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert {:ok, trusted} = Catalog.trust_pack_version(pack_version.id, subject)
      assert trusted.trust_state == :trusted
      assert trusted.hash == "sha256:NEW"
      assert trusted.pending_hash == nil
    end

    test "reject after drift drops pending_hash and keeps trusted hash" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:KEEP"}})
        )

      # Operator approves KEEP, then runner advertises DROP. Reject
      # should revert to KEEP.
      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.trust_pack_version(pack_version.id, subject)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:DROP"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert {:ok, after_reject} = Catalog.reject_pack_version(pack_version.id, subject)
      assert after_reject.trust_state == :trusted
      assert after_reject.hash == "sha256:KEEP"
      assert after_reject.pending_hash == nil
    end

    test "trust on a never-trusted custom pack adopts the advertised hash" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:NEW"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert pack_version.trust_state == :pending
      assert pack_version.hash == nil

      assert {:ok, trusted} = Catalog.trust_pack_version(pack_version.id, subject)
      assert trusted.trust_state == :trusted
      assert trusted.hash == "sha256:NEW"
      assert trusted.pending_hash == nil
    end

    test "reject on a never-trusted custom pack persists a :rejected row (fail-closed)" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:NOPE"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert {:ok, rejected} = Catalog.reject_pack_version(pack_version.id, subject)

      # The row is NOT deleted — it stays as an explicit :rejected pin so the
      # action that references this version resolves to "untrusted", not the
      # fail-open "missing row = trusted" the old delete left behind.
      assert rejected.trust_state == :rejected
      assert rejected.hash == nil
      assert rejected.pending_hash == nil
      assert {:ok, [persisted], _} = Catalog.list_pack_versions(subject)
      assert persisted.id == pack_version.id
      assert persisted.trust_state == :rejected
    end

    test "a re-advertised hash flips a :rejected row back to :pending for re-review" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:NOPE"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.reject_pack_version(pack_version.id, subject)

      # The runner advertises a fresh hash later — the operator gets another
      # decision instead of the rejected row silently re-trusting.
      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:FRESH"}})
        )

      {:ok, [reopened], _} = Catalog.list_pack_versions(subject)
      assert reopened.trust_state == :pending
      assert reopened.pending_hash == "sha256:FRESH"
    end

    test "viewer subject is denied trust/reject" do
      {_user, account, owner_subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)
      viewer = user_fixture()
      viewer_subject = subject_for(viewer, account, role: :viewer)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:A"}})
        )

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:B"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(owner_subject)
      assert {:error, :unauthorized} = Catalog.trust_pack_version(pack_version.id, viewer_subject)

      assert {:error, :unauthorized} =
               Catalog.reject_pack_version(pack_version.id, viewer_subject)
    end

    # closes ENG-005-T11 — Trust/Reject serialize on the FOR-NO-KEY-UPDATE lock;
    # once a row is no longer pending the loser gets :not_pending. Asserted
    # sequentially: a second decision on an already-trusted row is the loser's view.
    test "a second trust/reject on an already-decided row is :not_pending" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:ONCE"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.trust_pack_version(pack_version.id, subject)

      # The row is now :trusted (not pending) — the locked re-read rejects the race loser.
      assert {:error, :not_pending} = Catalog.trust_pack_version(pack_version.id, subject)
      assert {:error, :not_pending} = Catalog.reject_pack_version(pack_version.id, subject)
    end

    # closes ENG-005-T16 — Trust/Reject are account-scoped via the locked re-read's
    # Authorizer.for_subject; another account's owner can't touch this pin. The
    # two-gate model resolves a cross-account id to :not_found (404), not :unauthorized.
    test "trust/reject of another account's pin is :not_found (cross-account)" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:A"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)

      {_user_b, _account_b, subject_b} = owner_subject_fixture()
      assert {:error, :not_found} = Catalog.trust_pack_version(pack_version.id, subject_b)
      assert {:error, :not_found} = Catalog.reject_pack_version(pack_version.id, subject_b)

      # A's pin is untouched.
      assert {:ok, [unchanged], _} = Catalog.list_pack_versions(subject)
      assert unchanged.trust_state == :pending
    end
  end

  describe "trust / reject write an audit row" do
    # closes GOV-010-T10 — trusting a pending pack version writes a
    # `pack_trust_adopted` audit event attributing the decision to the operator,
    # subject-keyed to the pack_version, with the previous→new hash in the payload.
    test "trust writes a pack_trust_adopted audit event (actor + subject + hashes)" do
      {user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:ADOPT"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.trust_pack_version(pack_version.id, subject)

      {:ok, events, _} = Audit.list_events(subject)
      audit = Enum.find(events, &(&1.event_type == "pack_trust_adopted"))

      assert audit, "expected a pack_trust_adopted audit row"
      assert audit.subject_kind == "pack_version"
      assert audit.subject_id == pack_version.id
      assert audit.subject_label == "p@1.0"
      assert audit.actor_kind == "user"
      assert audit.actor_id == user.id
      # The pre-trust row had no trusted hash; the pending bytes are what got adopted.
      assert audit.payload["previous_hash"] == nil
      assert audit.payload["new_hash"] == "sha256:ADOPT"
      assert audit.payload["pack_id"] == "p"
    end

    # closes GOV-011-T10 — rejecting a pending pack version writes a
    # `pack_trust_rejected` audit event, same operator attribution + pack_version
    # subject, carrying the rejected hash.
    test "reject writes a pack_trust_rejected audit event (actor + subject + hash)" do
      {user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:NOPE"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.reject_pack_version(pack_version.id, subject)

      {:ok, events, _} = Audit.list_events(subject)
      audit = Enum.find(events, &(&1.event_type == "pack_trust_rejected"))

      assert audit, "expected a pack_trust_rejected audit row"
      assert audit.subject_kind == "pack_version"
      assert audit.subject_id == pack_version.id
      assert audit.subject_label == "p@1.0"
      assert audit.actor_kind == "user"
      assert audit.actor_id == user.id
      # Never-trusted custom pack — no trusted hash, the advertised bytes were rejected.
      assert audit.payload["trusted_hash"] == nil
      assert audit.payload["rejected_hash"] == "sha256:NOPE"
      assert audit.payload["pack_id"] == "p"
    end
  end

  describe "trusted_manifest capture + action_set_changes/2" do
    # Trust a pack version after observing `actions`, returning the now-trusted
    # %PackVersion{} (with its snapshotted manifest loaded).
    defp trust_with_actions(runner, subject, hash, actions) do
      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(
            packs: %{"acme" => %{"version" => "1.0", "hash" => hash}},
            actions: actions
          )
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      {:ok, trusted} = Catalog.trust_pack_version(pack_version.id, subject)
      trusted
    end

    test "trusting snapshots the current action set into trusted_manifest" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      trusted =
        trust_with_actions(runner, subject, "sha256:V1", [
          action("acme.status", pack_id: "acme", risk: "low", kind: "exec"),
          action("acme.reload", pack_id: "acme", risk: "high", kind: "script")
        ])

      # JSONB → string keys/values, one entry per action_id.
      assert trusted.trusted_manifest == %{
               "acme.status" => %{"risk" => "low", "kind" => "exec"},
               "acme.reload" => %{"risk" => "high", "kind" => "script"}
             }
    end

    test "a re-advertised hash that ADDS a (critical) action → diff lists it as added" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        trust_with_actions(runner, subject, "sha256:V1", [
          action("acme.status", pack_id: "acme", risk: "low")
        ])

      # New hash adds a critical action → flips back to pending.
      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(
            packs: %{"acme" => %{"version" => "1.0", "hash" => "sha256:V2"}},
            actions: [
              action("acme.status", pack_id: "acme", risk: "low"),
              action("acme.wipe", pack_id: "acme", risk: "critical")
            ]
          )
        )

      {:ok, [pending], _} = Catalog.list_pack_versions(subject)
      assert pending.trust_state == :pending
      {:ok, advertised} = Catalog.list_pack_actions("acme", "1.0", subject)

      diff = Catalog.action_set_changes(pending, advertised)
      assert [%{action_id: "acme.wipe", risk: "critical"}] = diff.added
      assert diff.removed == []
      assert diff.changed == []
    end

    test "a dropped action → removed; a low→critical escalation → changed with old+new" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        trust_with_actions(runner, subject, "sha256:V1", [
          action("acme.status", pack_id: "acme", risk: "low"),
          action("acme.gone", pack_id: "acme", risk: "medium")
        ])

      # acme.gone disappears; acme.status escalates low → critical.
      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(
            packs: %{"acme" => %{"version" => "1.0", "hash" => "sha256:V2"}},
            actions: [action("acme.status", pack_id: "acme", risk: "critical")]
          )
        )

      {:ok, [pending], _} = Catalog.list_pack_versions(subject)
      {:ok, advertised} = Catalog.list_pack_actions("acme", "1.0", subject)
      diff = Catalog.action_set_changes(pending, advertised)

      assert [%{action_id: "acme.gone", risk: "medium"}] = diff.removed
      assert diff.added == []

      assert [
               %{
                 action_id: "acme.status",
                 old_risk: "low",
                 new_risk: "critical",
                 risk_escalated?: true
               }
             ] = diff.changed
    end

    test "a pending version with a nil manifest (never trusted) → empty diff, no crash" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      # First-sight custom pack lands pending with NO trusted_manifest.
      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(
            packs: %{"acme" => %{"version" => "1.0", "hash" => "sha256:NEW"}},
            actions: [action("acme.status", pack_id: "acme", risk: "low")]
          )
        )

      {:ok, [pending], _} = Catalog.list_pack_versions(subject)
      assert pending.trusted_manifest == nil
      {:ok, advertised} = Catalog.list_pack_actions("acme", "1.0", subject)

      assert Catalog.action_set_changes(pending, advertised) == %{
               added: [],
               removed: [],
               changed: []
             }
    end

    test "the trusted_manifest is account-scoped — account B can't read account A's" do
      {_user_a, account_a, subject_a} = owner_subject_fixture()
      runner_a = runner_fixture(account_id: account_a.id)

      _ =
        trust_with_actions(runner_a, subject_a, "sha256:V1", [
          action("acme.secret", pack_id: "acme", risk: "high")
        ])

      # Account B observes the same pack id/version — its own pending row, no
      # manifest, and it never sees account A's pack_version at all.
      {_user_b, account_b, subject_b} = owner_subject_fixture()
      runner_b = runner_fixture(account_id: account_b.id)

      {:ok, _} =
        Catalog.observe_state(
          runner_b,
          state_payload(
            packs: %{"acme" => %{"version" => "1.0", "hash" => "sha256:OTHER"}},
            actions: [action("acme.other", pack_id: "acme", risk: "low")]
          )
        )

      {:ok, [pending_b], _} = Catalog.list_pack_versions(subject_b)
      assert pending_b.account_id == account_b.id
      assert pending_b.trusted_manifest == nil

      # Account A's trusted row is the only one A sees, carrying A's manifest.
      {:ok, [trusted_a], _} = Catalog.list_pack_versions(subject_a)
      assert trusted_a.account_id == account_a.id
      assert Map.has_key?(trusted_a.trusted_manifest, "acme.secret")
    end
  end

  describe "check_pack_trusted/1" do
    test "trusted state → :ok" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(
            packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:OK"}},
            actions: [action("a.b", pack_id: "p")]
          )
        )

      # Custom pack lands pending — operator approves before dispatch.
      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.trust_pack_version(pack_version.id, subject)

      {:ok, [act], _} = Catalog.list_actions_for_runner(runner.id, subject)
      assert {:ok, hash} = Catalog.check_pack_trusted(act)
      assert is_binary(hash)
    end

    test "pending state → {:error, :pack_untrusted, _}" do
      runner = runner_fixture()

      _ =
        Catalog.observe_state(
          runner,
          state_payload(
            packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:H1"}},
            actions: [action("a.b", pack_id: "p")]
          )
        )

      _ =
        Catalog.observe_state(
          runner,
          state_payload(
            packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:H2"}},
            actions: [action("a.b", pack_id: "p")]
          )
        )

      account = Emisar.Repo.preload(runner, :account).account
      subject = subject_for(user_fixture(), account, role: :owner)
      {:ok, [act], _} = Catalog.list_actions_for_runner(runner.id, subject)
      assert {:error, :pack_untrusted, _pv} = Catalog.check_pack_trusted(act)
    end

    test "action without pack_version (not yet pinnable) → {:ok, nil} (no hash to snapshot)" do
      runner = runner_fixture()
      act = %RunnerAction{pack_id: "p", pack_version: nil, account_id: runner.account_id}
      assert {:ok, nil} = Catalog.check_pack_trusted(act)
    end
  end

  describe "most_severe_risk_by_action/1" do
    test "keeps the worst risk when one action_id is advertised by several runners" do
      # The same action on two runners (mixed pack versions / a stale
      # runner) — a fleet dispatch hits both, so the map must surface the
      # worst risk regardless of which row was seen most recently.
      rows = [
        %RunnerAction{action_id: "shared.op", risk: :low},
        %RunnerAction{action_id: "shared.op", risk: :critical},
        %RunnerAction{action_id: "shared.op", risk: :medium},
        %RunnerAction{action_id: "calm.read", risk: :low}
      ]

      assert Catalog.most_severe_risk_by_action(rows) == %{
               "shared.op" => :critical,
               "calm.read" => :low
             }
    end

    test "is an empty map for no rows" do
      assert Catalog.most_severe_risk_by_action([]) == %{}
    end
  end

  describe "max_risk/1" do
    test "is nil for an empty list (no pill rather than a false low)" do
      assert Catalog.max_risk([]) == nil
    end

    test "returns the most-severe risk across a mix" do
      assert Catalog.max_risk([:low, :critical, :medium]) == :critical
      assert Catalog.max_risk([:low, :medium]) == :medium
      assert Catalog.max_risk([:high]) == :high
    end

    test "ignores an unresolved (nil) risk without lowering the result" do
      # A step whose action no runner advertises is nil — it must NOT drag a
      # critical runbook down to low. The worst known risk still wins.
      assert Catalog.max_risk([nil, :critical]) == :critical
      assert Catalog.max_risk([:low, nil, :high]) == :high
    end

    test "is nil when every risk is unresolved (all-unknown ≠ low)" do
      # A runbook whose every step is unobserved reads as "unknown" (no pill),
      # never as a falsely-low risk.
      assert Catalog.max_risk([nil, nil]) == nil
    end
  end

  describe "risk_by_action_ids/2" do
    test "resolves only the requested ids, keeping the worst across runners" do
      {account, subject} = account_with_owner()
      r1 = runner_fixture(account_id: account.id)
      r2 = runner_fixture(account_id: account.id)

      # `shared.op` advertised at two different risks across runners → worst wins.
      {:ok, _} =
        Catalog.observe_state(
          r1,
          state_payload(
            actions: [action("shared.op", risk: "low"), action("calm.read", risk: "low")]
          )
        )

      {:ok, _} =
        Catalog.observe_state(r2, state_payload(actions: [action("shared.op", risk: "high")]))

      # `untracked` is requested but no runner advertises it → absent (so a
      # caller's max_risk treats it as unknown, never a false low).
      assert {:ok, risk_by_action} =
               Catalog.risk_by_action_ids(["shared.op", "calm.read", "untracked"], subject)

      assert risk_by_action == %{"shared.op" => :high, "calm.read" => :low}
    end

    test "an empty id list short-circuits to an empty map" do
      {_account, subject} = account_with_owner()
      assert {:ok, %{}} = Catalog.risk_by_action_ids([], subject)
    end

    test "is account-scoped — another account's actions don't leak" do
      {account, _subject} = account_with_owner()
      runner = runner_fixture(account_id: account.id)

      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(actions: [action("secret.op", risk: "critical")])
        )

      {_other_account, other_subject} = account_with_owner()
      assert {:ok, %{}} = Catalog.risk_by_action_ids(["secret.op"], other_subject)
    end

    test "a subject without view_catalog is denied" do
      {account, _subject} = account_with_owner()
      no_view = %Emisar.Auth.Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert {:error, :unauthorized} = Catalog.risk_by_action_ids(["x"], no_view)
      # The empty-list clause gates too — no DB-free bypass of the permission check.
      assert {:error, :unauthorized} = Catalog.risk_by_action_ids([], no_view)
    end
  end

  describe "runner_ids_advertising_pack/3" do
    test "returns distinct advertising runners, account-scoped" do
      account = account_fixture()
      subject = subject_for(user_fixture(), account, role: :owner)
      r1 = runner_fixture(account_id: account.id)
      r2 = runner_fixture(account_id: account.id)

      pending =
        state_payload(
          packs: %{"linux-core" => %{"version" => "1.0", "hash" => "abc"}},
          actions: [
            action("linux.uptime", pack_id: "linux-core"),
            action("linux.df", pack_id: "linux-core")
          ]
        )

      {:ok, _} = Catalog.observe_state(r1, pending)
      {:ok, _} = Catalog.observe_state(r2, pending)

      # Same pack advertised in another account must not leak in.
      other = account_fixture()
      other_runner = runner_fixture(account_id: other.id)
      {:ok, _} = Catalog.observe_state(other_runner, pending)

      {:ok, ids} = Catalog.runner_ids_advertising_pack("linux-core", "1.0", subject)

      # r1 advertises two actions but appears once (distinct); the foreign
      # account's runner is scoped out.
      assert Enum.sort(ids) == Enum.sort([r1.id, r2.id])
    end
  end
end
