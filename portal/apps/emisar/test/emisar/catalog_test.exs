defmodule Emisar.CatalogTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Audit, Catalog, Repo, Runners}
  alias Emisar.Catalog.{PackVersion, RunnerAction}
  alias Emisar.Fixtures

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
      "summary" => Keyword.get(opts, :summary),
      "kind" => Keyword.get(opts, :kind, "exec"),
      "risk" => Keyword.get(opts, :risk, "low"),
      "description" => Keyword.get(opts, :description, "test"),
      "side_effects" => Keyword.get(opts, :side_effects, []),
      "args" => Keyword.get(opts, :args, []),
      "examples" => Keyword.get(opts, :examples, []),
      "search_terms" => Keyword.get(opts, :search_terms, [])
    }
  end

  defp account_with_owner do
    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    _ =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    {account, Fixtures.Subjects.subject_for(user, account, role: :owner)}
  end

  describe "observe_state/2 — packs" do
    setup do
      runner = Fixtures.Runners.create_runner()
      account = Emisar.Repo.preload(runner, :account).account
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      %{runner: runner, account: account, subject: subject}
    end

    test "upserts pack_versions", %{runner: runner, subject: subject} do
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

    test "commits runner facts while ignoring a malformed pack descriptor", %{runner: runner} do
      payload = state_payload(version: "9.9.9", packs: %{"bad" => "not-a-map"})

      assert {:ok, _runner} = Catalog.observe_state(runner, payload)

      reloaded = Emisar.Runners.peek_runner_by_id(runner.id)
      assert reloaded.runner_version == "9.9.9"
    end

    test "an apply_state error does not crash observe_state; the catalog still syncs", %{
      runner: runner,
      subject: subject
    } do
      payload =
        state_payload(
          labels: "not-a-map",
          actions: [action("linux.uptime")]
        )

      assert {:ok, returned} = Catalog.observe_state(runner, payload)
      assert returned.id == runner.id

      assert {:ok, [%RunnerAction{action_id: "linux.uptime"}], _} =
               Catalog.list_actions_for_runner(runner.id, subject)
    end

    test "accepts the aggregate catalog limits", %{runner: runner} do
      packs = Map.new(1..128, &{"pack-#{&1}", "malformed"})
      actions = List.duplicate(nil, 2_048)
      payload = state_payload(packs: packs, actions: actions)

      assert {:ok, _runner} = Catalog.observe_state(runner, payload)
    end

    test "rejects a non-object packs field with a stable error", %{runner: runner} do
      payload = state_payload(packs: [])

      assert Catalog.observe_state(runner, payload) ==
               {:error, {:invalid_catalog, "packs must be an object with at most 128 entries"}}
    end

    test "rejects more than 128 packs before catalog persistence", %{
      runner: runner,
      subject: subject
    } do
      packs =
        Map.new(1..129, fn index ->
          {"pack-#{index}", %{"version" => "1.0.0", "hash" => "sha256:#{index}"}}
        end)

      payload =
        state_payload(
          version: "rejected-version",
          packs: packs,
          actions: [action("overflow.run")]
        )

      assert Catalog.observe_state(runner, payload) ==
               {:error, {:invalid_catalog, "packs contains 129 entries; maximum is 128"}}

      assert Repo.reload!(runner).runner_version == runner.runner_version
      assert {:ok, [], _metadata} = Catalog.list_pack_versions(subject)
      assert {:ok, [], _metadata} = Catalog.list_actions_for_runner(runner.id, subject)
    end
  end

  describe "observe_state/2 — actions" do
    setup do
      runner = Fixtures.Runners.create_runner()
      account = Emisar.Repo.preload(runner, :account).account
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      %{runner: runner, account: account, subject: subject}
    end

    test "upserts runner_actions", %{runner: runner, subject: subject} do
      payload =
        state_payload(actions: [action("linux.uptime"), action("linux.df", risk: "medium")])

      assert {:ok, _runner} = Catalog.observe_state(runner, payload)

      {:ok, actions, _} = Catalog.list_actions_for_runner(runner.id, subject)
      assert length(actions) == 2
      assert Enum.any?(actions, &(&1.action_id == "linux.uptime" and &1.risk == :low))
      assert Enum.any?(actions, &(&1.action_id == "linux.df" and &1.risk == :medium))
    end

    test "persists the full 512-character summary contract", %{
      runner: runner,
      subject: subject
    } do
      summary = String.duplicate("s", 512)
      payload = state_payload(actions: [action("linux.uptime", summary: summary)])

      assert {:ok, _runner} = Catalog.observe_state(runner, payload)

      assert {:ok, [%RunnerAction{summary: ^summary}], _} =
               Catalog.list_actions_for_runner(runner.id, subject)
    end

    test "prunes actions no longer advertised", %{runner: runner, subject: subject} do
      {:ok, _runner} =
        Catalog.observe_state(
          runner,
          state_payload(actions: [action("linux.a"), action("linux.b"), action("linux.c")])
        )

      assert {:ok, actions, _} = Catalog.list_actions_for_runner(runner.id, subject)
      assert length(actions) == 3

      _ = Catalog.observe_state(runner, state_payload(actions: [action("linux.a")]))

      assert {:ok, [%RunnerAction{action_id: "linux.a"}], _} =
               Catalog.list_actions_for_runner(runner.id, subject)
    end

    test "an empty actions list removes every previously advertised action", %{
      runner: runner,
      subject: subject
    } do
      {:ok, _runner} =
        Catalog.observe_state(
          runner,
          state_payload(actions: [action("linux.a"), action("linux.b")])
        )

      assert {:ok, _runner} = Catalog.observe_state(runner, state_payload(actions: []))
      assert {:ok, [], _metadata} = Catalog.list_actions_for_runner(runner.id, subject)
    end

    test "a wholly malformed non-empty actions list preserves the last valid catalog", %{
      runner: runner,
      subject: subject
    } do
      {:ok, _runner} =
        Catalog.observe_state(
          runner,
          state_payload(actions: [action("linux.a"), action("linux.b")])
        )

      malformed = [nil, %{"id" => "not a valid action id"}]

      assert {:ok, _runner} =
               Catalog.observe_state(runner, state_payload(actions: malformed))

      assert {:ok, actions, _metadata} = Catalog.list_actions_for_runner(runner.id, subject)
      assert Enum.map(actions, & &1.action_id) == ["linux.a", "linux.b"]
    end

    test "rejects a non-array actions field with a stable error", %{runner: runner} do
      payload = state_payload(actions: %{})

      assert Catalog.observe_state(runner, payload) ==
               {:error, {:invalid_catalog, "actions must be an array with at most 2048 entries"}}
    end

    test "rejects more than 2048 actions before catalog persistence", %{
      runner: runner,
      subject: subject
    } do
      actions = List.duplicate(action("overflow.run"), 2_049)

      payload =
        state_payload(
          packs: %{"new-pack" => %{"version" => "1.0.0", "hash" => "sha256:new"}},
          actions: actions
        )

      assert Catalog.observe_state(runner, payload) ==
               {:error, {:invalid_catalog, "actions contains 2049 entries; maximum is 2048"}}

      assert {:ok, [], _metadata} = Catalog.list_pack_versions(subject)
      assert {:ok, [], _metadata} = Catalog.list_actions_for_runner(runner.id, subject)
    end

    test "updates the runner row's hostname/labels/version", %{runner: runner} do
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

    # a descriptor naming a pack_id NOT in the packs map
    # gets pack_version: nil defensively (vs. raising), and the row still upserts
    # so one missing pack reference doesn't drop the action from the catalog.
    test "an action referencing an unknown pack_id upserts with pack_version nil", %{
      runner: runner,
      subject: subject
    } do
      # The action's pack_id ("absent") is not a key in the (empty) packs map.
      payload = state_payload(actions: [action("orphan.do", pack_id: "absent")])

      assert {:ok, _runner} = Catalog.observe_state(runner, payload)

      assert {:ok, [%RunnerAction{action_id: "orphan.do", pack_version: nil}], _} =
               Catalog.list_actions_for_runner(runner.id, subject)
    end
  end

  describe "observe_state/2 — runner_id variant" do
    test "looks up the runner by id" do
      runner = Fixtures.Runners.create_runner()
      account = Emisar.Repo.preload(runner, :account).account
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      assert {:ok, _runner} =
               Catalog.observe_state(runner.id, state_payload(actions: [action("linux.a")]))

      assert {:ok, [%RunnerAction{action_id: "linux.a"}], _} =
               Catalog.list_actions_for_runner(runner.id, subject)
    end

    test "returns {:error, :unknown_runner} for an unknown id" do
      assert {:error, :unknown_runner} = Catalog.observe_state(Ecto.UUID.generate(), %{})
    end

    test "rejects an advertisement from a disabled runner" do
      {account, subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      {:ok, _disabled} = Runners.disable_runner(runner, subject)

      assert {:error, :unknown_runner} =
               Catalog.observe_state(runner.id, state_payload(actions: [action("linux.uptime")]))

      assert {:ok, [], _} = Catalog.list_actions_for_runner(runner.id, subject)
    end
  end

  describe "observe_state_from_connection/4" do
    test "rejects a superseded connection before runner or catalog mutation" do
      runner = Fixtures.Runners.create_runner(connected?: true)

      assert {:ok, updated} =
               Catalog.observe_state_from_connection(
                 runner.id,
                 state_payload(hostname: "owned"),
                 runner.connection_generation,
                 runner.connection_lease_id
               )

      assert updated.hostname == "owned"

      assert {:error, :connection_superseded} =
               Catalog.observe_state_from_connection(
                 runner.id,
                 state_payload(hostname: "stale"),
                 runner.connection_generation,
                 Ecto.UUID.generate()
               )

      assert Repo.reload!(runner).hostname == "owned"
    end
  end

  describe "observe_state/2 — trust pinning" do
    test "unknown pack first sight → pending, awaits operator approval" do
      runner = Fixtures.Runners.create_runner()
      account = Emisar.Repo.preload(runner, :account).account
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

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
      runner = Fixtures.Runners.create_runner()
      account = Emisar.Repo.preload(runner, :account).account
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

      payload =
        state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:H1"}})

      assert {:ok, _} = Catalog.observe_state(runner, payload)
      assert {:ok, _} = Catalog.observe_state(runner, payload)

      assert {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert pack_version.trust_state == :pending
      assert pack_version.pending_hash == "sha256:H1"
    end

    test "hash change after operator-trust → pending again" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

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
      account = Fixtures.Accounts.create_account()
      runner_a = Fixtures.Runners.create_runner(account_id: account.id)
      runner_b = Fixtures.Runners.create_runner(account_id: account.id)
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)

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
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      payload =
        state_payload(packs: %{"x" => %{"version" => "1.0", "hash" => "sha256:H1"}})

      assert {:ok, _} = Catalog.observe_state(runner, payload)
      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.trust_pack_version(pack_version.id, subject)
      assert {:ok, _} = Catalog.observe_state(runner, payload)

      assert {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert pack_version.trust_state == :trusted
    end

    test "baseline auto-trust persists release-frozen prose, never the runner advertisement" do
      [pack | _] =
        Application.app_dir(:emisar, "priv/packs/catalog.json")
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("packs")

      [catalog_action | _] = pack["actions"]
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert {:ok, _} =
               Catalog.observe_state(
                 runner,
                 state_payload(
                   packs: %{
                     pack["id"] => %{
                       "version" => pack["version"],
                       "hash" => pack["content_hash"]
                     }
                   },
                   actions: [
                     action(catalog_action["id"],
                       pack_id: pack["id"],
                       description: "attacker-authored replacement prose"
                     )
                   ]
                 )
               )

      assert {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert pack_version.trust_state == :trusted
      assert {:ok, manifest} = Catalog.trusted_manifest_for_static_reads(pack_version)

      descriptor = manifest["actions"][catalog_action["id"]]
      assert descriptor["description"] == catalog_action["description"]
      refute descriptor["description"] == "attacker-authored replacement prose"
      refute Map.has_key?(descriptor, "command")
    end

    test "a matching heartbeat repairs a pre-manifest baseline trust decision" do
      [pack | _] =
        Application.app_dir(:emisar, "priv/packs/catalog.json")
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("packs")

      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      payload =
        state_payload(
          packs: %{
            pack["id"] => %{
              "version" => pack["version"],
              "hash" => pack["content_hash"]
            }
          }
        )

      assert {:ok, _} = Catalog.observe_state(runner, payload)
      assert {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)

      pack_version
      |> Ecto.Changeset.change(trusted_manifest: nil)
      |> Repo.update!()

      assert {:ok, _} = Catalog.observe_state(runner, payload)
      assert {:ok, [repaired], _} = Catalog.list_pack_versions(subject)
      assert {:ok, manifest} = Catalog.trusted_manifest_for_static_reads(repaired)
      assert map_size(manifest["actions"]) == length(pack["actions"])
    end
  end

  describe "trust_pack_version/2" do
    setup do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{user: user, account: account, subject: subject, runner: runner}
    end

    test "trust adopts pending_hash as the trusted hash", %{subject: subject, runner: runner} do
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
      # A non-retired version is not overridden by the trust — trust_changeset(false).
      assert trusted.retirement_overridden_at == nil
    end

    test "trust on a never-trusted custom pack adopts the advertised hash", %{
      subject: subject,
      runner: runner
    } do
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

    test "trust snapshots only descriptors bound to the exact pending hash", %{
      account: account,
      subject: subject,
      runner: first_runner
    } do
      second_runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert {:ok, _} =
               Catalog.observe_state(
                 first_runner,
                 state_payload(
                   packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:H1"}},
                   actions: [
                     action("custom.inspect",
                       pack_id: "custom",
                       description: "Descriptor for H1."
                     )
                   ]
                 )
               )

      assert {:ok, _} =
               Catalog.observe_state(
                 second_runner,
                 state_payload(
                   packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:H2"}},
                   actions: [
                     action("custom.inspect",
                       pack_id: "custom",
                       description: "Descriptor for H2."
                     )
                   ]
                 )
               )

      assert {:ok, [pending], _} = Catalog.list_pack_versions(subject)
      assert pending.pending_hash == "sha256:H2"
      assert {:ok, trusted} = Catalog.trust_pack_version(pending.id, subject)

      assert get_in(trusted.trusted_manifest, ["actions", "custom.inspect", "description"]) ==
               "Descriptor for H2."
    end

    test "malformed model metadata aborts trust and leaves the decision pending", %{
      subject: subject,
      runner: runner
    } do
      assert {:ok, _} =
               Catalog.observe_state(
                 runner,
                 state_payload(
                   packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:BAD"}},
                   actions: [
                     action("custom.inspect",
                       pack_id: "custom",
                       title: String.duplicate("t", 161)
                     )
                   ]
                 )
               )

      assert {:ok, [pending], _} = Catalog.list_pack_versions(subject)
      assert {:error, :invalid_manifest} = Catalog.trust_pack_version(pending.id, subject)
      assert {:ok, [unchanged], _} = Catalog.list_pack_versions(subject)
      assert unchanged.trust_state == :pending
      assert unchanged.pending_hash == "sha256:BAD"
    end

    test "an oversized complete descriptor aborts trust", %{subject: subject, runner: runner} do
      assert {:ok, _} =
               Catalog.observe_state(
                 runner,
                 state_payload(
                   packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:HUGE"}},
                   actions: [
                     action("custom.inspect",
                       pack_id: "custom",
                       examples: [
                         %{
                           "title" => "Oversized",
                           "args" => %{"payload" => String.duplicate("x", 40_000)}
                         }
                       ]
                     )
                   ]
                 )
               )

      assert {:ok, [pending], _} = Catalog.list_pack_versions(subject)
      assert {:error, :invalid_manifest} = Catalog.trust_pack_version(pending.id, subject)
    end

    # trusting a pending pack version writes a
    # `pack_trust_adopted` audit event attributing the decision to the operator,
    # subject-keyed to the pack_version, with the previous→new hash in the payload.
    test "writes a pack_trust_adopted audit event (actor + subject + hashes)", %{
      user: user,
      subject: subject,
      runner: runner
    } do
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
      assert audit.target_kind == "pack_version"
      assert audit.target_id == pack_version.id
      assert audit.target_label == "p@1.0"
      assert audit.actor_kind == "user"
      assert audit.actor_id == user.id
      # The pre-trust row had no trusted hash; the pending bytes are what got adopted.
      assert audit.payload["previous_hash"] == nil
      assert audit.payload["new_hash"] == "sha256:ADOPT"
      assert audit.payload["pack_id"] == "p"
      # A non-retired version threads retired: false through to the audit payload.
      assert audit.payload["retired"] == false
    end

    test "a viewer subject is denied trust", %{
      account: account,
      subject: owner_subject,
      runner: runner
    } do
      viewer = Fixtures.Users.create_user()
      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:A"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(owner_subject)
      assert {:error, :unauthorized} = Catalog.trust_pack_version(pack_version.id, viewer_subject)
    end

    # Trust/Reject of another account's pin is account-scoped via the locked
    # re-read's Authorizer.for_subject; the two-gate model resolves a
    # cross-account id to :not_found (404), not :unauthorized.
    test "trust of another account's pin is :not_found (cross-account)", %{
      subject: subject,
      runner: runner
    } do
      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:A"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert {:error, :not_found} = Catalog.trust_pack_version(pack_version.id, subject_b)

      # A's pin is untouched.
      assert {:ok, [unchanged], _} = Catalog.list_pack_versions(subject)
      assert unchanged.trust_state == :pending
    end

    # Trust/Reject serialize on the FOR-NO-KEY-UPDATE lock;
    # once a row is no longer pending the loser gets :not_pending. Asserted
    # sequentially: a second decision on an already-trusted row is the loser's view.
    test "a second trust on an already-decided row is :not_pending", %{
      subject: subject,
      runner: runner
    } do
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

    test "broadcasts the pack-trust change after the flip commits", %{
      account: account,
      subject: subject,
      runner: runner
    } do
      account_id = account.id
      Catalog.subscribe_account_packs(account_id)

      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "h1"}})
        )

      assert_receive {:pack_trust_changed, ^account_id}

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.trust_pack_version(pack_version.id, subject)
      assert_receive {:pack_trust_changed, ^account_id}
    end
  end

  describe "reject_pack_version/2" do
    setup do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{user: user, account: account, subject: subject, runner: runner}
    end

    test "reject after drift drops pending_hash and keeps trusted hash", %{
      subject: subject,
      runner: runner
    } do
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

    test "reject on a never-trusted custom pack persists a :rejected row (fail-closed)", %{
      subject: subject,
      runner: runner
    } do
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

    test "a re-advertised hash flips a :rejected row back to :pending for re-review", %{
      subject: subject,
      runner: runner
    } do
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

    # rejecting a pending pack version writes a
    # `pack_trust_rejected` audit event, same operator attribution + pack_version
    # subject, carrying the rejected hash.
    test "writes a pack_trust_rejected audit event (actor + subject + hash)", %{
      user: user,
      subject: subject,
      runner: runner
    } do
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
      assert audit.target_kind == "pack_version"
      assert audit.target_id == pack_version.id
      assert audit.target_label == "p@1.0"
      assert audit.actor_kind == "user"
      assert audit.actor_id == user.id
      # Never-trusted custom pack — no trusted hash, the advertised bytes were rejected.
      assert audit.payload["trusted_hash"] == nil
      assert audit.payload["rejected_hash"] == "sha256:NOPE"
      assert audit.payload["pack_id"] == "p"
    end

    test "a viewer subject is denied reject", %{
      account: account,
      subject: owner_subject,
      runner: runner
    } do
      viewer = Fixtures.Users.create_user()
      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:A"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(owner_subject)

      assert {:error, :unauthorized} =
               Catalog.reject_pack_version(pack_version.id, viewer_subject)
    end

    test "reject of another account's pin is :not_found (cross-account)", %{
      subject: subject,
      runner: runner
    } do
      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:A"}})
        )

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert {:error, :not_found} = Catalog.reject_pack_version(pack_version.id, subject_b)

      # A's pin is untouched.
      assert {:ok, [unchanged], _} = Catalog.list_pack_versions(subject)
      assert unchanged.trust_state == :pending
    end

    test "broadcasts the pack-trust change after the reject commits", %{
      account: account,
      subject: subject,
      runner: runner
    } do
      account_id = account.id
      Catalog.subscribe_account_packs(account_id)

      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "h1"}})
        )

      assert_receive {:pack_trust_changed, ^account_id}

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      assert {:ok, _} = Catalog.reject_pack_version(pack_version.id, subject)
      assert_receive {:pack_trust_changed, ^account_id}
    end
  end

  describe "override_pack_retirement/2" do
    setup do
      {user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:OK"}})
        )

      {:ok, [pending], _} = Catalog.list_pack_versions(subject)
      {:ok, trusted} = Catalog.trust_pack_version(pending.id, subject)

      %{user: user, account: account, subject: subject, runner: runner, pack_version: trusted}
    end

    test "stamps retirement_overridden_at + who and audits the override", %{
      user: user,
      subject: subject,
      pack_version: pack_version
    } do
      assert {:ok, overridden} = Catalog.override_pack_retirement(pack_version.id, subject)
      assert %DateTime{} = overridden.retirement_overridden_at
      assert overridden.retirement_overridden_by_id == user.id
      assert overridden.trust_state == :trusted

      {:ok, events, _} = Audit.list_events(subject)
      audit = Enum.find(events, &(&1.event_type == "pack_retirement_overridden"))

      assert audit, "expected a pack_retirement_overridden audit row"
      assert audit.target_kind == "pack_version"
      assert audit.target_id == pack_version.id
      assert audit.actor_kind == "user"
      assert audit.actor_id == user.id
      assert audit.payload["pack_id"] == "custom"
      assert audit.payload["version"] == "1.0"
    end

    test "a viewer subject is denied", %{account: account, pack_version: pack_version} do
      viewer = Fixtures.Users.create_user()
      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} =
               Catalog.override_pack_retirement(pack_version.id, viewer_subject)
    end

    test "override of another account's pin is :not_found (cross-account)", %{
      pack_version: pack_version
    } do
      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert {:error, :not_found} = Catalog.override_pack_retirement(pack_version.id, subject_b)
    end

    test "a pending (non-trusted) row is rejected with :not_trusted", %{
      subject: subject,
      runner: runner
    } do
      _ =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"other" => %{"version" => "2.0", "hash" => "sha256:P"}})
        )

      {:ok, versions, _} = Catalog.list_pack_versions(subject)
      pending = Enum.find(versions, &(&1.pack_id == "other"))
      assert pending.trust_state == :pending

      assert {:error, :not_trusted} = Catalog.override_pack_retirement(pending.id, subject)
    end

    test "an invalid id is :not_found", %{subject: subject} do
      assert {:error, :not_found} = Catalog.override_pack_retirement("not-a-uuid", subject)
    end
  end

  describe "check_pack_trusted/1" do
    test "trusted state → :ok" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

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

    test "trusted → returns the trusted hash to snapshot, never the pending one" do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      _ =
        Catalog.observe_state(
          runner,
          state_payload(
            packs: %{"p" => %{"version" => "1.0", "hash" => "sha256:NEW"}},
            actions: [action("p.do", pack_id: "p", title: "Do")]
          )
        )

      {:ok, action} = Catalog.fetch_action_for_account("p.do", runner.id, account.id)

      # Custom pack, never trusted → no hash to snapshot (untrusted).
      assert {:error, :pack_untrusted, _} = Catalog.check_pack_trusted(action)

      {:ok, [pack_version], _} = Catalog.list_pack_versions(subject)
      {:ok, _} = Catalog.trust_pack_version(pack_version.id, subject)

      assert {:ok, "sha256:NEW"} = Catalog.check_pack_trusted(action)
    end

    test "pending state → {:error, :pack_untrusted, _}" do
      runner = Fixtures.Runners.create_runner()

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
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      {:ok, [act], _} = Catalog.list_actions_for_runner(runner.id, subject)
      assert {:error, :pack_untrusted, _pv} = Catalog.check_pack_trusted(act)
    end

    # fail-CLOSED on a MISSING pin row. `runner_actions`
    # reference (pack_id, version) by string with no FK, so an action carrying a
    # version that has no pack_versions pin row must read as untrusted (:no_pin),
    # never fall open to trusted (the old design deleted the row on reject).
    test "fails closed with :no_pin when no pin row exists" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

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

    test "action without pack_version (not yet pinnable) → {:ok, nil} (no hash to snapshot)" do
      runner = Fixtures.Runners.create_runner()
      act = %RunnerAction{pack_id: "p", pack_version: nil, account_id: runner.account_id}
      assert {:ok, nil} = Catalog.check_pack_trusted(act)
    end

    test "a pack-less action (no pack_id) → {:ok, nil}" do
      assert {:ok, nil} = Catalog.check_pack_trusted(%RunnerAction{pack_id: nil})
    end
  end

  # The compiled PackBaseline can't be fixtured (no shipped pack is retired), so
  # this pure fn — the dispatch seam check_pack_trusted composes with the real
  # PackBaseline.retired?/2 — carries the exhaustive retirement branch coverage.
  describe "trusted_row_dispatch_decision/2" do
    test "not retired → {:ok, hash}" do
      pack_version = %PackVersion{hash: "sha256:OK", retirement_overridden_at: nil}
      assert Catalog.trusted_row_dispatch_decision(pack_version, false) == {:ok, "sha256:OK"}
    end

    test "retired but overridden → {:ok, hash}" do
      pack_version = %PackVersion{hash: "sha256:OK", retirement_overridden_at: DateTime.utc_now()}
      assert Catalog.trusted_row_dispatch_decision(pack_version, true) == {:ok, "sha256:OK"}
    end

    test "retired with no override → {:error, :pack_retired, pack_version}" do
      pack_version = %PackVersion{hash: "sha256:OK", retirement_overridden_at: nil}

      assert Catalog.trusted_row_dispatch_decision(pack_version, true) ==
               {:error, :pack_retired, pack_version}
    end
  end

  describe "pack_version_retirement/1" do
    # The `{:retired, current}` branch lives at the same compiled-baseline seam
    # as `trusted_row_dispatch_decision/2`: no shipped pack carries a retirement
    # watermark, so a real row is always `:active`. The retired branch's parts —
    # `PackBaseline.retired?/2` + `current_version/1` — are unit-tested against
    # a synthetic watermark in `PackBaselineTest`; here we lock the `:active`
    # composition over real rows.
    test "is :active for a shipped current version" do
      {{pack_id, version}, _hash} = Emisar.Catalog.PackBaseline.all() |> Enum.at(0)
      pack_version = %PackVersion{pack_id: pack_id, version: version}

      assert Catalog.pack_version_retirement(pack_version) == :active
    end

    test "is :active for a custom pack the release does not ship" do
      pack_version = %PackVersion{pack_id: "definitely-not-a-real-pack", version: "9.9.9"}

      assert Catalog.pack_version_retirement(pack_version) == :active
    end
  end

  describe "list_actions_for_runner/3" do
    setup do
      {account, subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, subject: subject, runner: runner}
    end

    test "lists the actions a runner advertises, scoped to the subject's account", %{
      subject: subject,
      runner: runner
    } do
      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(actions: [action("linux.uptime"), action("linux.df", risk: "medium")])
        )

      assert {:ok, actions, _meta} = Catalog.list_actions_for_runner(runner.id, subject)
      assert Enum.map(actions, & &1.action_id) |> Enum.sort() == ["linux.df", "linux.uptime"]
    end

    test "another account's subject sees none of this runner's actions (cross-account)", %{
      runner: runner
    } do
      {:ok, _} = Catalog.observe_state(runner, state_payload(actions: [action("linux.uptime")]))

      {_other_account, other_subject} = account_with_owner()
      assert {:ok, [], _} = Catalog.list_actions_for_runner(runner.id, other_subject)
    end

    test "a subject without view_catalog is denied", %{account: account, runner: runner} do
      no_view = %Emisar.Auth.Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert {:error, :unauthorized} = Catalog.list_actions_for_runner(runner.id, no_view)
    end
  end

  describe "list_all_actions_for_account/1" do
    test "returns the COMPLETE catalog — no pagination cap — scoped to the account" do
      {account, subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      # 40 actions — past the paginator's 35-row default page.
      advertised = for n <- 1..40, do: action("pack.act_#{n}")
      {:ok, _} = Catalog.observe_state(runner, state_payload(actions: advertised))

      {:ok, all} = Catalog.list_all_actions_for_account(subject)
      assert length(all) == 40

      # Another account sees none of them.
      {_account, other_subject} = account_with_owner()
      assert {:ok, []} = Catalog.list_all_actions_for_account(other_subject)
    end
  end

  describe "risk_by_action_ids/2" do
    setup do
      {account, subject} = account_with_owner()
      %{account: account, subject: subject}
    end

    test "resolves only the requested ids, keeping the worst across runners", %{
      account: account,
      subject: subject
    } do
      r1 = Fixtures.Runners.create_runner(account_id: account.id)
      r2 = Fixtures.Runners.create_runner(account_id: account.id)

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

    test "an empty id list short-circuits to an empty map", %{subject: subject} do
      assert {:ok, %{}} = Catalog.risk_by_action_ids([], subject)
    end

    test "is account-scoped — another account's actions don't leak", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(actions: [action("secret.op", risk: "critical")])
        )

      {_other_account, other_subject} = account_with_owner()
      assert {:ok, %{}} = Catalog.risk_by_action_ids(["secret.op"], other_subject)
    end

    test "a subject without view_catalog is denied", %{account: account} do
      no_view = %Emisar.Auth.Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert {:error, :unauthorized} = Catalog.risk_by_action_ids(["x"], no_view)
      # The empty-list clause gates too — no DB-free bypass of the permission check.
      assert {:error, :unauthorized} = Catalog.risk_by_action_ids([], no_view)
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

  describe "action_risks_for_account/1" do
    setup do
      {account, subject} = account_with_owner()
      %{account: account, subject: subject}
    end

    test "distinct action => risk, worst risk winning across runners", %{
      account: account,
      subject: subject
    } do
      r1 = Fixtures.Runners.create_runner(account_id: account.id)
      r2 = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _} =
        Catalog.observe_state(
          r1,
          state_payload(
            actions: [
              action("linux.uptime", risk: "low"),
              action("nginx.reload", risk: "medium"),
              # low here, critical on r2 below → the worst wins.
              action("docker.stop", risk: "low")
            ]
          )
        )

      {:ok, _} =
        Catalog.observe_state(
          r2,
          state_payload(actions: [action("docker.stop", risk: "critical")])
        )

      assert {:ok, risks} = Catalog.action_risks_for_account(subject)

      assert risks == %{
               "linux.uptime" => :low,
               "nginx.reload" => :medium,
               "docker.stop" => :critical
             }
    end

    test "is empty for a fresh account", %{subject: subject} do
      assert {:ok, %{}} = Catalog.action_risks_for_account(subject)
    end

    test "is account-scoped — another account's actions don't leak", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(actions: [action("secret.op", risk: "critical")])
        )

      {_other_account, other_subject} = account_with_owner()
      assert {:ok, %{}} = Catalog.action_risks_for_account(other_subject)
    end

    test "a subject without view_catalog is denied", %{account: account} do
      no_view = %Emisar.Auth.Subject{account: account, role: :runner, permissions: MapSet.new()}
      assert {:error, :unauthorized} = Catalog.action_risks_for_account(no_view)
    end
  end

  describe "action_risks_for_runner_ids/2" do
    setup do
      {account, subject} = account_with_owner()
      %{account: account, subject: subject}
    end

    test "scopes to the given runners, worst risk winning across them", %{
      account: account,
      subject: subject
    } do
      r1 = Fixtures.Runners.create_runner(account_id: account.id)
      r2 = Fixtures.Runners.create_runner(account_id: account.id)
      other = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _} =
        Catalog.observe_state(
          r1,
          state_payload(
            actions: [action("shared.op", risk: "low"), action("r1.only", risk: "high")]
          )
        )

      {:ok, _} =
        Catalog.observe_state(r2, state_payload(actions: [action("shared.op", risk: "critical")]))

      {:ok, _} =
        Catalog.observe_state(
          other,
          state_payload(actions: [action("elsewhere.op", risk: "critical")])
        )

      # A "group" of r1 + r2: shared.op dedups to its worst (critical); `other` is out of scope.
      assert {:ok, risks} = Catalog.action_risks_for_runner_ids([r1.id, r2.id], subject)
      assert risks == %{"shared.op" => :critical, "r1.only" => :high}

      # One runner sees only its own rows — shared.op is low on r1 alone.
      assert {:ok, r1_only} = Catalog.action_risks_for_runner_ids([r1.id], subject)
      assert r1_only == %{"shared.op" => :low, "r1.only" => :high}
    end

    test "an empty runner-id list is the empty map", %{subject: subject} do
      assert {:ok, %{}} = Catalog.action_risks_for_runner_ids([], subject)
    end

    test "is account-scoped — a foreign runner id contributes nothing", %{account: account} do
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(actions: [action("secret.op", risk: "critical")])
        )

      {_other_account, other_subject} = account_with_owner()
      assert {:ok, %{}} = Catalog.action_risks_for_runner_ids([runner.id], other_subject)
    end

    test "a subject without view_catalog is denied — empty and non-empty", %{account: account} do
      no_view = %Emisar.Auth.Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert {:error, :unauthorized} = Catalog.action_risks_for_runner_ids(["r"], no_view)
      assert {:error, :unauthorized} = Catalog.action_risks_for_runner_ids([], no_view)
    end
  end

  describe "action_risk_index_for_account/1" do
    setup do
      {account, subject} = account_with_owner()
      %{account: account, subject: subject}
    end

    test "returns account and per-runner risk maps from the scoped catalog", %{
      account: account,
      subject: subject
    } do
      r1 = Fixtures.Runners.create_runner(account_id: account.id)
      r2 = Fixtures.Runners.create_runner(account_id: account.id)
      foreign = Fixtures.Runners.create_runner()

      {:ok, _} =
        Catalog.observe_state(
          r1,
          state_payload(
            actions: [action("shared.op", risk: "low"), action("r1.only", risk: "high")]
          )
        )

      {:ok, _} =
        Catalog.observe_state(r2, state_payload(actions: [action("shared.op", risk: "critical")]))

      {:ok, _} =
        Catalog.observe_state(
          foreign,
          state_payload(actions: [action("foreign.secret", risk: "critical")])
        )

      assert {:ok, index} = Catalog.action_risk_index_for_account(subject)

      assert index.account == %{"shared.op" => :critical, "r1.only" => :high}
      assert index.runners[r1.id] == %{"shared.op" => :low, "r1.only" => :high}
      assert index.runners[r2.id] == %{"shared.op" => :critical}
      refute Map.has_key?(index.runners, foreign.id)

      assert Catalog.action_risks_from_index(index, [r1.id, r2.id]) == %{
               "shared.op" => :critical,
               "r1.only" => :high
             }

      assert Catalog.action_risks_from_index(index, [foreign.id]) == %{}
    end

    test "is empty for a fresh account", %{subject: subject} do
      assert {:ok, %{account: %{}, runners: %{}}} = Catalog.action_risk_index_for_account(subject)
    end

    test "a subject without view_catalog is denied", %{account: account} do
      no_view = %Emisar.Auth.Subject{account: account, role: :runner, permissions: MapSet.new()}
      assert {:error, :unauthorized} = Catalog.action_risk_index_for_account(no_view)
    end
  end

  describe "action_risks_from_index/2" do
    test "merges selected runners with worst risk winning and unknown ids ignored" do
      index = %{
        account: %{},
        runners: %{
          "runner-1" => %{"shared.op" => :low, "r1.only" => :high},
          "runner-2" => %{"shared.op" => :critical}
        }
      }

      assert Catalog.action_risks_from_index(index, ["runner-1", "runner-2", "missing"]) == %{
               "shared.op" => :critical,
               "r1.only" => :high
             }
    end
  end

  describe "risk_breakdown_of/1" do
    test "buckets an action => risk map into a per-tier count" do
      risks = %{
        "docker.ps" => :low,
        "linux.uptime" => :low,
        "z.low" => :low,
        "aaa.low" => :low,
        "nginx.reload" => :medium,
        "linux.reboot_host" => :high,
        "wipe.disk" => :critical
      }

      breakdown = Catalog.risk_breakdown_of(risks)

      assert breakdown["low"] == 4
      assert breakdown["medium"] == 1
      assert breakdown["high"] == 1
      assert breakdown["critical"] == 1
    end

    test "every tier is present — an empty map is 0 across the board" do
      breakdown = Catalog.risk_breakdown_of(%{})

      for tier <- ["low", "medium", "high", "critical"] do
        assert breakdown[tier] == 0
      end
    end
  end

  describe "fetch_action_by_id/3" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, subject: subject, runner: runner}
    end

    test "scopes to the subject's account and rejects junk ids", %{
      account: account,
      subject: subject,
      runner: runner
    } do
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")

      assert {:ok, action} = Catalog.fetch_action_by_id("linux.uptime", runner.id, subject)
      assert action.account_id == account.id

      assert {:error, :not_found} = Catalog.fetch_action_by_id("linux.uptime", "junk", subject)
    end

    test "another account's subject can't fetch the action (cross-account)", %{
      subject: subject,
      runner: runner
    } do
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")

      assert {:ok, _} = Catalog.fetch_action_by_id("linux.uptime", runner.id, subject)

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()

      assert {:error, :not_found} =
               Catalog.fetch_action_by_id("linux.uptime", runner.id, subject_b)
    end

    test "a subject without view_catalog is denied", %{account: account, runner: runner} do
      no_view = %Emisar.Auth.Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert {:error, :unauthorized} =
               Catalog.fetch_action_by_id("linux.uptime", runner.id, no_view)
    end
  end

  describe "fetch_action_for_account/3" do
    test "resolves an action scoped to the explicit account (the subject-less system path)" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")

      assert {:ok, %RunnerAction{action_id: "linux.uptime", account_id: id}} =
               Catalog.fetch_action_for_account("linux.uptime", runner.id, account.id)

      assert id == account.id
    end

    test "is account-scoped — a different account_id resolves to :not_found" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      _ = Fixtures.Catalog.create_action(runner: runner, action_id: "linux.uptime")

      other_account = Fixtures.Accounts.create_account()

      assert {:error, :not_found} =
               Catalog.fetch_action_for_account("linux.uptime", runner.id, other_account.id)
    end

    test "an unknown action_id is :not_found" do
      account = Fixtures.Accounts.create_account()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      assert {:error, :not_found} =
               Catalog.fetch_action_for_account("nope.do", runner.id, account.id)
    end
  end

  describe "list_pack_versions/2" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{account: account, subject: subject, runner: runner}
    end

    test "lists the account's pinned pack versions", %{subject: subject, runner: runner} do
      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"linux-core" => %{"version" => "1.0", "hash" => "abc"}})
        )

      assert {:ok, [%PackVersion{pack_id: "linux-core", version: "1.0"}], _meta} =
               Catalog.list_pack_versions(subject)
    end

    test "another account's pins don't leak in (cross-account)", %{runner: runner} do
      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"linux-core" => %{"version" => "1.0", "hash" => "abc"}})
        )

      {_user_b, _account_b, subject_b} = Fixtures.Subjects.owner_subject()
      assert {:ok, [], _} = Catalog.list_pack_versions(subject_b)
    end

    test "a subject without view_catalog is denied", %{account: account} do
      no_view = %Emisar.Auth.Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert {:error, :unauthorized} = Catalog.list_pack_versions(no_view)
    end

    test "preload: [:retirement_overridden_by] loads the overriding admin, and it's absent by default",
         %{subject: subject, runner: runner} do
      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(packs: %{"custom" => %{"version" => "1.0", "hash" => "sha256:OK"}})
        )

      {:ok, [pending], _} = Catalog.list_pack_versions(subject)
      {:ok, trusted} = Catalog.trust_pack_version(pending.id, subject)
      {:ok, _} = Catalog.override_pack_retirement(trusted.id, subject)

      {:ok, [preloaded], _} =
        Catalog.list_pack_versions(subject, preload: [:retirement_overridden_by])

      assert %Emisar.Users.User{id: user_id} = preloaded.retirement_overridden_by
      assert user_id == preloaded.retirement_overridden_by_id

      {:ok, [bare], _} = Catalog.list_pack_versions(subject)
      assert %Ecto.Association.NotLoaded{} = bare.retirement_overridden_by
    end
  end

  describe "list_all_pack_versions_for_account/1" do
    test "returns the complete account-scoped set in deterministic pack order" do
      {account, subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _runner} =
        Catalog.observe_state(
          runner,
          state_payload(
            packs: %{
              "zeta" => %{"version" => "2.0", "hash" => "zeta-hash"},
              "alpha" => %{"version" => "1.0", "hash" => "alpha-hash"}
            }
          )
        )

      assert {:ok, pack_versions} = Catalog.list_all_pack_versions_for_account(subject)

      assert Enum.map(pack_versions, &{&1.pack_id, &1.version}) == [
               {"alpha", "1.0"},
               {"zeta", "2.0"}
             ]
    end

    test "denies a subject without view-catalog permission" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.build_subject(account: account, role: :billing_manager)

      assert Catalog.list_all_pack_versions_for_account(subject) == {:error, :unauthorized}
    end

    test "never returns another account's rows" do
      {account_a, subject_a} = account_with_owner()
      {account_b, subject_b} = account_with_owner()
      runner_a = Fixtures.Runners.create_runner(account_id: account_a.id)
      runner_b = Fixtures.Runners.create_runner(account_id: account_b.id)

      {:ok, _runner_a} =
        Catalog.observe_state(
          runner_a,
          state_payload(packs: %{"alpha" => %{"version" => "1.0", "hash" => "a"}})
        )

      {:ok, _runner_b} =
        Catalog.observe_state(
          runner_b,
          state_payload(packs: %{"beta" => %{"version" => "1.0", "hash" => "b"}})
        )

      assert {:ok, [%PackVersion{pack_id: "alpha"}]} =
               Catalog.list_all_pack_versions_for_account(subject_a)

      assert {:ok, [%PackVersion{pack_id: "beta"}]} =
               Catalog.list_all_pack_versions_for_account(subject_b)
    end
  end

  describe "runner_ids_advertising_pack/3" do
    test "returns distinct advertising runners, account-scoped" do
      account = Fixtures.Accounts.create_account()
      subject = Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :owner)
      r1 = Fixtures.Runners.create_runner(account_id: account.id)
      r2 = Fixtures.Runners.create_runner(account_id: account.id)

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
      other = Fixtures.Accounts.create_account()
      other_runner = Fixtures.Runners.create_runner(account_id: other.id)
      {:ok, _} = Catalog.observe_state(other_runner, pending)

      {:ok, ids} = Catalog.runner_ids_advertising_pack("linux-core", "1.0", subject)

      # r1 advertises two actions but appears once (distinct); the foreign
      # account's runner is scoped out.
      assert Enum.sort(ids) == Enum.sort([r1.id, r2.id])
    end
  end

  describe "list_pack_actions/3" do
    test "returns the distinct actions a pack version advertises, scoped to the account" do
      {account, subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      other_runner = Fixtures.Runners.create_runner(account_id: account.id)

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

      {:ok, _} =
        Catalog.observe_state(
          other_runner,
          state_payload(
            packs: %{"acme" => %{"version" => "2.0", "hash" => "h"}},
            actions: [action("acme.reload", pack_id: "acme", risk: "critical")]
          )
        )

      assert {:ok, actions} = Catalog.list_pack_actions("acme", "2.0", subject)
      # Ordered by action_id, one row per action (deduped across runners).
      assert Enum.map(actions, & &1.action_id) == ["acme.reload", "acme.status"]
      assert Enum.map(actions, & &1.risk) == [:critical, :low]

      # Another account sees none of this account's pack actions.
      {_account, other_subject} = account_with_owner()
      assert {:ok, []} = Catalog.list_pack_actions("acme", "2.0", other_subject)
    end
  end

  describe "pack_actions_index/1" do
    test "keys every pack version's deduped actions by {pack_id, pack_version}" do
      {account, subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      other_runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(
            packs: %{
              "acme" => %{"version" => "2.0", "hash" => "h"},
              "linux" => %{"version" => "1.0", "hash" => "h2"}
            },
            actions: [
              action("acme.reload", pack_id: "acme", risk: "high"),
              action("acme.status", pack_id: "acme", risk: "low"),
              action("linux.reboot", pack_id: "linux", risk: "critical")
            ]
          )
        )

      {:ok, _} =
        Catalog.observe_state(
          other_runner,
          state_payload(
            packs: %{"acme" => %{"version" => "2.0", "hash" => "h"}},
            actions: [action("acme.reload", pack_id: "acme", risk: "critical")]
          )
        )

      assert {:ok, index} = Catalog.pack_actions_index(subject)

      assert index |> Map.keys() |> Enum.sort() == [{"acme", "2.0"}, {"linux", "1.0"}]
      # Deduped + ordered by action_id within a pack version.
      assert Enum.map(index[{"acme", "2.0"}], & &1.action_id) == ["acme.reload", "acme.status"]
      assert Enum.map(index[{"acme", "2.0"}], & &1.risk) == [:critical, :low]
      assert Enum.map(index[{"linux", "1.0"}], & &1.risk) == [:critical]
    end

    test "another account's actions never leak into the index" do
      {account, _subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

      {:ok, _} =
        Catalog.observe_state(
          runner,
          state_payload(
            packs: %{"acme" => %{"version" => "2.0", "hash" => "h"}},
            actions: [action("acme.reload", pack_id: "acme", risk: "high")]
          )
        )

      {_other, other_subject} = account_with_owner()
      assert {:ok, index} = Catalog.pack_actions_index(other_subject)
      assert index == %{}
    end
  end

  describe "action_set_changes/2" do
    setup do
      {_user, account, subject} = Fixtures.Subjects.owner_subject()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      %{subject: subject, runner: runner}
    end

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

    test "trusting snapshots the current action set into trusted_manifest", %{
      subject: subject,
      runner: runner
    } do
      trusted =
        trust_with_actions(runner, subject, "sha256:V1", [
          action("acme.status", pack_id: "acme", risk: "low", kind: "exec"),
          action("acme.reload", pack_id: "acme", risk: "high", kind: "script")
        ])

      assert trusted.trusted_manifest["schema_version"] == 1
      actions = trusted.trusted_manifest["actions"]
      assert actions |> Map.keys() |> Enum.sort() == ["acme.reload", "acme.status"]
      assert actions["acme.status"]["risk"] == "low"
      assert actions["acme.status"]["kind"] == "exec"
      assert actions["acme.status"]["description"] == "test"
      assert actions["acme.reload"]["risk"] == "high"
      assert actions["acme.reload"]["kind"] == "script"
    end

    test "a re-advertised hash that ADDS a (critical) action → diff lists it as added", %{
      subject: subject,
      runner: runner
    } do
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

    test "a dropped action → removed; a low→critical escalation → changed with old+new", %{
      subject: subject,
      runner: runner
    } do
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

    test "a pending version with a nil manifest (never trusted) → empty diff, no crash", %{
      subject: subject,
      runner: runner
    } do
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
      {_user_a, account_a, subject_a} = Fixtures.Subjects.owner_subject()
      runner_a = Fixtures.Runners.create_runner(account_id: account_a.id)

      _ =
        trust_with_actions(runner_a, subject_a, "sha256:V1", [
          action("acme.secret", pack_id: "acme", risk: "high")
        ])

      # Account B observes the same pack id/version — its own pending row, no
      # manifest, and it never sees account A's pack_version at all.
      {_user_b, account_b, subject_b} = Fixtures.Subjects.owner_subject()
      runner_b = Fixtures.Runners.create_runner(account_id: account_b.id)

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
      assert Map.has_key?(trusted_a.trusted_manifest["actions"], "acme.secret")
    end
  end

  describe "trusted_manifest_for_static_reads/1" do
    test "bounds each model-facing side effect without rejecting detailed safety guidance" do
      base_action = %RunnerAction{
        action_id: "custom.inspect",
        title: "Inspect",
        description: "Inspect state.",
        kind: :exec,
        risk: :low,
        args_schema: %{"args" => []},
        examples: [],
        search_terms: []
      }

      assert {:ok, _manifest} =
               Emisar.Catalog.TrustedManifest.from_runner_actions([
                 %{base_action | side_effects: [String.duplicate("a", 1_024)]}
               ])

      assert {:error, :invalid_manifest} =
               Emisar.Catalog.TrustedManifest.from_runner_actions([
                 %{base_action | side_effects: [String.duplicate("a", 1_025)]}
               ])
    end

    test "accepts only trusted rows carrying a complete versioned manifest" do
      {:ok, manifest} =
        Emisar.Catalog.TrustedManifest.from_runner_actions([
          %RunnerAction{
            action_id: "custom.inspect",
            title: "Inspect",
            description: "Inspect state.",
            kind: :exec,
            risk: :low,
            side_effects: [],
            args_schema: %{"args" => []},
            examples: [],
            search_terms: []
          }
        ])

      assert {:ok, ^manifest} =
               Catalog.trusted_manifest_for_static_reads(%PackVersion{
                 trust_state: :trusted,
                 trusted_manifest: manifest
               })

      assert {:error, :incomplete_manifest} =
               Catalog.trusted_manifest_for_static_reads(%PackVersion{
                 trust_state: :trusted,
                 trusted_manifest: %{
                   "custom.inspect" => %{"risk" => "low", "kind" => "exec"}
                 }
               })

      assert {:error, :pack_untrusted} =
               Catalog.trusted_manifest_for_static_reads(%PackVersion{
                 trust_state: :pending,
                 trusted_manifest: manifest
               })
    end
  end

  describe "count_pending_pack_versions/1" do
    test "counts pending versions for the account and never another account's" do
      {account, subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id)

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
      other_runner = Fixtures.Runners.create_runner(account_id: other_account.id)

      {:ok, _} =
        Catalog.observe_state(
          other_runner,
          state_payload(packs: %{"redis" => %{"version" => "9.9.9", "hash" => "h3"}})
        )

      assert Catalog.count_pending_pack_versions(subject) == 2
      assert Catalog.count_pending_pack_versions(other_subject) == 1
    end

    test "returns 0 for a subject without view_catalog (the badge silently disappears)" do
      {account, _subject} = account_with_owner()
      no_view = %Emisar.Auth.Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert Catalog.count_pending_pack_versions(no_view) == 0
    end
  end

  describe "subscribe_account_packs/1" do
    test "broadcasts when pending appears and is resolved, but not on a no-op observe" do
      {account, subject} = account_with_owner()
      runner = Fixtures.Runners.create_runner(account_id: account.id)
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

    test "a subscriber to account A does not receive account B's pack-trust broadcast" do
      {account_a, _subject_a} = account_with_owner()
      {account_b, _subject_b} = account_with_owner()
      runner_b = Fixtures.Runners.create_runner(account_id: account_b.id)

      Catalog.subscribe_account_packs(account_a.id)

      # The pending pack appears in B's account — A's subscriber must hear nothing.
      {:ok, _} =
        Catalog.observe_state(
          runner_b,
          state_payload(packs: %{"custom-pack" => %{"version" => "1.0", "hash" => "h1"}})
        )

      refute_receive {:pack_trust_changed, _}
    end
  end

  describe "subject_can_view_packs?/1" do
    test "true for a viewer, false for a billing_manager (the nav gate)" do
      account = Fixtures.Accounts.create_account()

      viewer_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account, role: :viewer)

      billing_manager_subject =
        Fixtures.Subjects.subject_for(Fixtures.Users.create_user(), account,
          role: :billing_manager
        )

      assert Catalog.subject_can_view_packs?(viewer_subject)
      refute Catalog.subject_can_view_packs?(billing_manager_subject)
    end
  end

  describe "subject_can_manage_packs?/1" do
    test "is true for an owner and an admin (manage_catalog holders)" do
      {_user, account, owner_subject} = Fixtures.Subjects.owner_subject()
      assert Catalog.subject_can_manage_packs?(owner_subject)

      admin = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      admin_subject = Fixtures.Subjects.subject_for(admin, account, role: :admin)
      assert Catalog.subject_can_manage_packs?(admin_subject)
    end

    test "is false for an operator and a viewer (view-only on the catalog)" do
      {_user, account, _owner_subject} = Fixtures.Subjects.owner_subject()

      operator = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: operator.id,
          role: "operator"
        )

      operator_subject = Fixtures.Subjects.subject_for(operator, account, role: :operator)
      refute Catalog.subject_can_manage_packs?(operator_subject)

      viewer = Fixtures.Users.create_user()

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      viewer_subject = Fixtures.Subjects.subject_for(viewer, account, role: :viewer)
      refute Catalog.subject_can_manage_packs?(viewer_subject)
    end
  end
end
