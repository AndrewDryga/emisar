defmodule Emisar.CatalogTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Catalog
  alias Emisar.Catalog.{RunnerAction, PackVersion}

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
                  trust_state: "pending"
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

      {:ok, reloaded} = Emisar.Runners.peek_runner_by_id(runner.id)
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

  describe "pack-trust PubSub" do
    test "broadcasts when pending appears and is resolved, but not on a no-op observe" do
      {account, subject} = account_with_owner()
      runner = runner_fixture(account_id: account.id)
      account_id = account.id
      Emisar.PubSub.subscribe_account_packs(account_id)

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
      {:ok, [pv], _} = Catalog.list_pack_versions(subject)
      {:ok, _} = Catalog.trust_pack_version(pv.id, subject)
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
      assert Enum.any?(actions, &(&1.action_id == "linux.uptime" and &1.risk == "low"))
      assert Enum.any?(actions, &(&1.action_id == "linux.df" and &1.risk == "medium"))
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

      assert {:ok, [pv], _} = Catalog.list_pack_versions(subject)
      assert pv.trust_state == "pending"
      assert pv.hash == nil
      assert pv.pending_hash == "sha256:custom"
    end

    test "custom pack: re-advertising the same pending hash is a touch (no drift event)" do
      runner = runner_fixture()
      account = Emisar.Repo.preload(runner, :account).account
      subject = subject_for(user_fixture(), account, role: :owner)

      payload =
        state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:H1"}})

      assert {:ok, _} = Catalog.observe_state(runner, payload)
      assert {:ok, _} = Catalog.observe_state(runner, payload)

      assert {:ok, [pv], _} = Catalog.list_pack_versions(subject)
      assert pv.trust_state == "pending"
      assert pv.pending_hash == "sha256:H1"
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
      {:ok, [pv], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.trust_pack_version(pv.id, subject)

      assert {:ok, _} =
               Catalog.observe_state(
                 runner,
                 state_payload(packs: %{"x" => %{"version" => "1.0", "hash" => "sha256:H2"}})
               )

      assert {:ok, [pv], _} = Catalog.list_pack_versions(subject)
      assert pv.trust_state == "pending"
      assert pv.hash == "sha256:H1"
      assert pv.pending_hash == "sha256:H2"
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
          fn r -> Catalog.observe_state(r, payload) end,
          max_concurrency: 2,
          ordered: false
        )

      results = tasks |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &match?({:ok, _}, &1)),
             "one of the concurrent observers crashed: #{inspect(results)}"

      assert {:ok, [pv], _} = Catalog.list_pack_versions(subject)
      assert pv.pack_id == "raceduck-custom-pack"
      assert pv.version == "0.3.0"
      # Custom pack — no library baseline, so it lands pending and
      # awaits operator approval. The pending_hash is the bytes both
      # racing runners advertised.
      assert pv.trust_state == "pending"
      assert pv.pending_hash == "sha256:RACE"
      assert pv.hash == nil
    end

    test "advertising the trusted hash again after approval → no-op (just touches last_seen)" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      payload =
        state_payload(packs: %{"x" => %{"version" => "1.0", "hash" => "sha256:H1"}})

      assert {:ok, _} = Catalog.observe_state(runner, payload)
      {:ok, [pv], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.trust_pack_version(pv.id, subject)
      assert {:ok, _} = Catalog.observe_state(runner, payload)

      assert {:ok, [pv], _} = Catalog.list_pack_versions(subject)
      assert pv.trust_state == "trusted"
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

      {:ok, [pv], _} = Catalog.list_pack_versions(subject)
      assert {:ok, trusted} = Catalog.trust_pack_version(pv.id, subject)
      assert trusted.trust_state == "trusted"
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
      {:ok, [pv], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.trust_pack_version(pv.id, subject)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:DROP"}})
        )

      {:ok, [pv], _} = Catalog.list_pack_versions(subject)
      assert {:ok, after_reject} = Catalog.reject_pack_version(pv.id, subject)
      assert after_reject.trust_state == "trusted"
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

      {:ok, [pv], _} = Catalog.list_pack_versions(subject)
      assert pv.trust_state == "pending"
      assert pv.hash == nil

      assert {:ok, trusted} = Catalog.trust_pack_version(pv.id, subject)
      assert trusted.trust_state == "trusted"
      assert trusted.hash == "sha256:NEW"
      assert trusted.pending_hash == nil
    end

    test "reject on a never-trusted custom pack deletes the row" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:NOPE"}})
        )

      {:ok, [pv], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.reject_pack_version(pv.id, subject)
      assert {:ok, [], _} = Catalog.list_pack_versions(subject)
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

      {:ok, [pv], _} = Catalog.list_pack_versions(owner_subject)
      assert {:error, :unauthorized} = Catalog.trust_pack_version(pv.id, viewer_subject)
      assert {:error, :unauthorized} = Catalog.reject_pack_version(pv.id, viewer_subject)
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
      {:ok, [pv], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.trust_pack_version(pv.id, subject)

      {:ok, [act], _} = Catalog.list_actions_for_runner(runner.id, subject)
      assert :ok = Catalog.check_pack_trusted(act)
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

    test "action without pack_version (legacy row) → :ok (no-op)" do
      runner = runner_fixture()
      act = %RunnerAction{pack_id: "p", pack_version: nil, account_id: runner.account_id}
      assert :ok = Catalog.check_pack_trusted(act)
    end
  end
end
