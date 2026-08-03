defmodule Emisar.Fixtures.Runners do
  @moduledoc """
  Runner + enrollment-key test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Runners.create_runner/1`.
  """

  alias Emisar.Accounts.Account
  alias Emisar.{Fixtures, Repo, Runners, Users}
  alias Emisar.Runners.Runner

  @doc """
  Persists a runner in `connected` status by default. Caller supplies
  `:account_id` (or the helper makes a fresh account).
  """
  def create_runner(attrs \\ %{}) do
    attrs = Map.new(attrs)

    account_id =
      attrs[:account_id] || Fixtures.Accounts.create_account().id

    params = %{
      account_id: account_id,
      name: attrs[:name] || Fixtures.Random.unique_runner_name(),
      external_id: attrs[:external_id] || Ecto.UUID.generate(),
      group: attrs[:group] || "default",
      hostname: attrs[:hostname] || "host-#{Fixtures.Random.unique_int()}",
      labels: attrs[:labels] || %{},
      runner_version: attrs[:runner_version] || "0.1.0",
      bootstrap_enrollment_key_id: attrs[:bootstrap_enrollment_key_id]
    }

    {:ok, runner} =
      params
      |> Runner.Changeset.register()
      |> Repo.insert()

    # `enforce_signatures` is advertised via runner_state, not registration —
    # apply it through the same changeset a real advertisement would.
    runner =
      if Map.get(attrs, :enforce_signatures) do
        {:ok, runner} =
          runner
          |> Runner.Changeset.apply_state(%{
            enforce_signatures: true,
            max_attestation_age_seconds: Map.get(attrs, :max_attestation_age_seconds, 86_400)
          })
          |> Repo.update()

        runner
      else
        runner
      end

    if Map.get(attrs, :connected?, true) do
      connect_runner(runner)
    else
      runner
    end
  end

  @doc """
  Rigs the connected state directly — claims a lease via the changeset and
  tracks presence from the calling (test) process (auto-untracked when it
  exits) — so arranging an online runner writes no `runner.connected` audit
  row the way the real `Runners.connect_runner/3` transition does.
  """
  def connect_runner(%Runner{} = runner) do
    lease_expires_at = DateTime.add(DateTime.utc_now(), 120, :second)

    {:ok, runner} =
      runner
      |> Runner.Changeset.connected(Ecto.UUID.generate(), lease_expires_at)
      |> Repo.update()

    meta = %{
      online_at: System.system_time(:second),
      action_load: 0,
      last_heartbeat_at: nil,
      connection_generation: runner.connection_generation,
      connection_lease_id: runner.connection_lease_id,
      node: node()
    }

    {:ok, _ref} =
      Runners.Presence.track(
        self(),
        Runners.Presence.topic(runner.account_id),
        runner.id,
        meta
      )

    runner
  end

  @doc """
  Creates a bootstrap enrollment key. Returns `{raw, key}` so callers can
  test both the raw secret + the persisted struct.
  """
  def create_enrollment_key(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || Fixtures.Accounts.create_account().id
    user_id = attrs[:created_by_id] || Fixtures.Users.create_user().id

    create_attrs =
      attrs
      |> Map.take([:description, :group, :reusable, :max_uses, :expires_at])

    account =
      Account.Query.not_deleted()
      |> Account.Query.by_id(account_id)
      |> Repo.fetch!(Account.Query)

    {:ok, user} = Users.fetch_user_by_id(user_id)
    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    {:ok, raw, key} = Runners.create_enrollment_key(create_attrs, subject)
    {raw, key}
  end

  @doc """
  Enrollment key persisted from a caller-supplied raw secret — the seed/dev
  bootstrap shape (`EnrollmentKey.Changeset.create_with_secret/4`). Tests use
  it to exercise the secret→key round-trip with a known raw value.
  """
  def create_enrollment_key_with_secret(raw, account_id, user_id, attrs \\ %{}) do
    {:ok, key} =
      Runners.EnrollmentKey.Changeset.create_with_secret(account_id, user_id, raw, attrs)
      |> Repo.insert()

    key
  end

  @doc """
  Rigs the runner's advertised `packs` map — the durable runner_state fact the
  catalog reads to answer which hosts are on a pack version — without replaying
  a whole runner_state payload. `packs` is the wire shape:
  `%{pack_id => %{"version" => v, "hash" => h}}`.
  """
  def advertise_packs(%Runner{} = runner, packs) when is_map(packs) do
    runner
    |> Runner.Changeset.apply_state(%{packs: packs})
    |> Repo.update!()
  end

  @doc """
  Rigs the packs the runner's loader skipped — the durable runner_state fact the
  console reads to explain a pack missing from the catalog. `degraded` is the
  stored shape: `[%{"pack" => name, "reason" => text}]`.
  """
  def advertise_degraded_packs(%Runner{} = runner, degraded) when is_list(degraded) do
    runner
    |> Runner.Changeset.apply_state(%{degraded_packs: degraded})
    |> Repo.update!()
  end

  @doc "Backdates the runner's connection-lease expiry so the next claim may take over."
  def expire_connection_lease(%Runner{} = runner) do
    runner
    |> Ecto.Changeset.change(
      connection_lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
    )
    |> Repo.update!()
  end

  @doc """
  Stamps a runner as durably disconnected at `at` (connected shortly before it),
  so the inactivity-retention sweep sees it offline since `at`. Pair with
  `create_runner(connected?: false)` to rig an offline-since-`at` runner.
  """
  def mark_disconnected_at(%Runner{} = runner, %DateTime{} = at) do
    runner
    |> Ecto.Changeset.change(
      last_connected_at: DateTime.add(at, -60, :second),
      last_disconnected_at: at,
      last_disconnect_reason: "test"
    )
    |> Repo.update!()
  end

  @doc "Disables a runner (sets `disabled_at`) to rig the disabled-state setup."
  def disable_runner(%Runner{} = runner) do
    runner
    |> Runner.Changeset.disable()
    |> Repo.update!()
  end

  @doc "Soft-deletes a runner (sets `deleted_at`) to rig the deleted-state setup."
  def mark_deleted(%Runner{} = runner) do
    runner
    |> Runner.Changeset.delete()
    |> Repo.update!()
  end
end
