defmodule Emisar.RunnersTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Billing
  alias Emisar.Repo
  alias Emisar.Runners
  alias Emisar.Runners.{AuthKey, Runner, Token}

  defp account_with_owner_subject do
    user = user_fixture()
    account = account_fixture()
    _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
    subject = subject_for(user, account, role: :owner)
    {account, user, subject}
  end

  defp filter_names(subject, status) do
    {:ok, runners, _} = Runners.list_runners_for_account(subject, status: status)
    runners |> Enum.map(& &1.name) |> Enum.sort()
  end

  describe "create_auth_key/2" do
    test "returns a raw secret + persists the hash with a prefix" do
      {account, user, subject} = account_with_owner_subject()

      assert {:ok, raw, %AuthKey{} = key} =
               Runners.create_auth_key(%{description: "for dev"}, subject)

      assert String.starts_with?(raw, "emkey-auth-")
      assert key.account_id == account.id
      assert key.created_by_id == user.id
      assert is_binary(key.key_hash)
      assert key.description == "for dev"
    end

    test "rejects max_uses: 0 at the write path, not just the form" do
      {_account, _user, subject} = account_with_owner_subject()

      # max_uses 0 mints a key that's dead on arrival; create/5 must enforce
      # the same `> 0` guard the editor form does, not rely on it.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Runners.create_auth_key(%{description: "dead", max_uses: 0}, subject)

      assert %{max_uses: ["must be greater than 0"]} = errors_on(changeset)
    end
  end

  describe "peek_auth_key_by_secret/1" do
    test "returns the key for a valid secret" do
      {_account, _user, subject} = account_with_owner_subject()
      {:ok, raw, %AuthKey{id: id}} = Runners.create_auth_key(%{reusable: true}, subject)

      assert %AuthKey{id: ^id} = Runners.peek_auth_key_by_secret(raw)
    end

    test "returns nil for a revoked key" do
      {_account, _user, subject} = account_with_owner_subject()
      {:ok, raw, key} = Runners.create_auth_key(%{reusable: true}, subject)
      {:ok, _} = Runners.revoke_auth_key(key, subject)

      refute Runners.peek_auth_key_by_secret(raw)
    end

    test "returns nil for an expired key" do
      {_account, _user, subject} = account_with_owner_subject()
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      {:ok, raw, _key} =
        Runners.create_auth_key(%{reusable: true, expires_at: past}, subject)

      refute Runners.peek_auth_key_by_secret(raw)
    end

    test "returns nil for a single-use key after first use" do
      {_account, _user, subject} = account_with_owner_subject()
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
  end

  describe "register_via_auth_key/2" do
    test "mints an runner + token on success" do
      account = account_fixture()
      user = user_fixture()

      {raw, _key} =
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

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
      account = account_fixture()
      user = user_fixture()

      {raw, _key} =
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

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
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

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
      account = account_fixture()
      user = user_fixture()

      {raw, _key} =
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

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
      account = account_fixture()
      user = user_fixture()

      {raw, _key} =
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

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
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

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
      account = account_fixture()
      user = user_fixture()

      {raw, _key} =
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

      attrs = %{hostname: "no-id-host", group: "g"}

      assert {:ok, %Runner{id: first_id}, _, _} = Runners.register_via_auth_key(raw, attrs)

      assert {:error, :runner_name_taken, "no-id-host"} =
               Runners.register_via_auth_key(raw, attrs)

      assert %Runner{} = Runners.peek_runner_by_id(first_id)
    end

    test "returns :over_limit when the plan cap is exceeded" do
      # `free` plan caps runners at 3.
      account = account_fixture(plan: "free")
      user = user_fixture()

      _ = runner_fixture(account_id: account.id)
      _ = runner_fixture(account_id: account.id)
      _ = runner_fixture(account_id: account.id)

      {raw, _key} =
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

      assert {:error, :over_limit, "free", 3} =
               Runners.register_via_auth_key(raw, %{group: "demo"})
    end

    test "a reconnecting runner at the plan cap still registers (its seat is already counted)" do
      # `free` caps runners at 3. Fill the account to the cap, with one runner
      # registered via a stable external_id so we can reconnect it.
      account = account_fixture(plan: "free")
      user = user_fixture()

      {raw, _key} =
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

      assert {:ok, %Runner{}, _, _} =
               Runners.register_via_auth_key(raw, %{external_id: "ext-keep", group: "g"})

      _ = runner_fixture(account_id: account.id)
      _ = runner_fixture(account_id: account.id)

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
      account = account_fixture()
      user = user_fixture()

      {raw, _key} =
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: false)

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
  end

  describe "create_runner/2 name conflicts" do
    test "an OFFLINE holder conflicts the same as a connected one" do
      {account, _user, subject} = account_with_owner_subject()
      holder = runner_fixture(account_id: account.id, name: "edge-01", connected?: false)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Runners.create_runner(%{"name" => "edge-01", "group" => "edge"}, subject)

      assert "is already used by another runner in this account" in errors_on(changeset).name
      assert %Runner{} = Runners.peek_runner_by_id(holder.id)
    end

    test "keeps the conflict when the holder is CONNECTED" do
      {account, _user, subject} = account_with_owner_subject()
      holder = runner_fixture(account_id: account.id, name: "edge-01", connected?: true)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Runners.create_runner(%{"name" => "edge-01", "group" => "edge"}, subject)

      assert "is already used by another runner in this account" in errors_on(changeset).name
      assert %Runner{} = Runners.peek_runner_by_id(holder.id)
    end
  end

  describe "verify_runner_token/1" do
    test "returns {:ok, token, runner} for a valid raw token" do
      account = account_fixture()
      user = user_fixture()

      {raw, _key} =
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

      {:ok, _agent, _token, raw_token} = Runners.register_via_auth_key(raw, %{group: "demo"})

      assert {:ok, %Token{} = token, %Runner{}} = Runners.verify_runner_token(raw_token)
      # `verify_runner_token` bumps last_used_at server-side; reload to observe.
      assert %Token{last_used_at: %DateTime{}} = Repo.reload!(token)
    end

    test "returns {:error, :token_invalid} for garbage" do
      assert {:error, :token_invalid} = Runners.verify_runner_token("rnrtok-garbage")
      assert {:error, :token_invalid} = Runners.verify_runner_token("")
    end

    test "returns {:error, :token_invalid} for a revoked token (via disabled runner)" do
      account = account_fixture()

      _ =
        membership_fixture(
          account_id: account.id,
          user_id: (user = user_fixture()).id,
          role: "owner"
        )

      subject = subject_for(user, account, role: :owner)

      {raw, _key} =
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

      {:ok, runner, _token, raw_token} = Runners.register_via_auth_key(raw, %{group: "demo"})

      {:ok, _} = Runners.disable_runner(runner, subject)

      assert {:error, :token_invalid} = Runners.verify_runner_token(raw_token)
    end
  end

  describe "disable_runner / delete_runner — live-socket kill switch" do
    test "disabling a runner broadcasts :runner_socket_revoked to drop its live socket" do
      {account, _user, subject} = account_with_owner_subject()
      runner = runner_fixture(account_id: account.id)

      # The live socket subscribes to this transport topic at connect; the
      # broadcast is what drops an already-open (now disabled) runner's session.
      Runners.subscribe_runner_transport(runner)

      assert {:ok, _} = Runners.disable_runner(runner, subject)
      assert_receive :runner_socket_revoked
    end

    test "deleting a runner broadcasts :runner_socket_revoked to drop its live socket" do
      {account, _user, subject} = account_with_owner_subject()
      runner = runner_fixture(account_id: account.id)

      Runners.subscribe_runner_transport(runner)

      assert {:ok, _} = Runners.delete_runner(runner, subject)
      assert_receive :runner_socket_revoked
    end
  end

  describe "connect_runner / mark_disconnected" do
    test "connect_runner tracks presence and stamps last_connected_at" do
      runner = runner_fixture(connected?: false)
      refute Runners.online?(runner.account_id, runner.id)

      assert {:ok, %Runner{last_connected_at: %DateTime{}}} = Runners.connect_runner(runner)
      assert Runners.online?(runner.account_id, runner.id)
    end

    test "id-based mark_disconnected returns :not_found for an unknown id" do
      assert {:error, :not_found} = Runners.mark_disconnected(Ecto.UUID.generate(), "gone")
    end

    test "id-based mark_disconnected stamps last_disconnected_at + reason" do
      runner = runner_fixture(connected?: false)

      assert {:ok, %Runner{last_disconnected_at: %DateTime{}, last_disconnect_reason: "shutdown"}} =
               Runners.mark_disconnected(runner.id, "shutdown")
    end
  end

  describe "record_heartbeat/3" do
    test "refreshes action_load + last heartbeat in presence metadata, not the DB" do
      runner = runner_fixture(connected?: false)
      {:ok, _} = Runners.connect_runner(runner)

      assert {:ok, _ref} = Runners.record_heartbeat(runner.account_id, runner.id, 7)

      assert %{metas: [meta | _]} =
               Runners.connection_metas(runner.account_id) |> Map.fetch!(runner.id)

      assert meta.action_load == 7
      assert is_integer(meta.last_heartbeat_at)
    end
  end

  describe "fleet_all_offline?/1" do
    test "true when there are billable runners and every one is offline" do
      {_user, account, subject} = owner_subject_fixture()
      _r1 = runner_fixture(account_id: account.id, connected?: false)
      _r2 = runner_fixture(account_id: account.id, connected?: false)

      assert Runners.fleet_all_offline?(subject)
    end

    test "false when at least one runner is online" do
      {_user, account, subject} = owner_subject_fixture()
      _offline = runner_fixture(account_id: account.id, connected?: false)
      online = runner_fixture(account_id: account.id, connected?: false)
      {:ok, _} = Runners.connect_runner(online)

      refute Runners.fleet_all_offline?(subject)
    end

    test "false when the account has no billable runners (nothing to alert on)" do
      {_user, _account, subject} = owner_subject_fixture()

      refute Runners.fleet_all_offline?(subject)
    end

    test "false (no badge) for a subject without view_runners" do
      {_owner, account, _owner_subject} = owner_subject_fixture()
      _r = runner_fixture(account_id: account.id, connected?: false)
      # An in-account subject that holds no permissions — exercises the gate's
      # deny branch directly (no membership role actually lacks view_runners, so
      # the realistic no-badge caller is a runner/system subject, not a UI user).
      no_view = %Emisar.Auth.Subject{account: account, role: :runner, permissions: MapSet.new()}

      refute Runners.fleet_all_offline?(no_view)
    end
  end

  describe "fleet_all_signed?/1" do
    test "true when there's at least one active runner and every one enforces signatures" do
      {_user, account, subject} = owner_subject_fixture()
      _r1 = runner_fixture(account_id: account.id, enforce_signatures: true, connected?: false)
      _r2 = runner_fixture(account_id: account.id, enforce_signatures: true, connected?: false)

      assert Runners.fleet_all_signed?(subject)
    end

    test "false when any active runner does not enforce" do
      {_user, account, subject} = owner_subject_fixture()

      _signed =
        runner_fixture(account_id: account.id, enforce_signatures: true, connected?: false)

      _plain = runner_fixture(account_id: account.id, connected?: false)

      refute Runners.fleet_all_signed?(subject)
    end

    test "false when the account has no runners (nothing to signal)" do
      {_user, _account, subject} = owner_subject_fixture()

      refute Runners.fleet_all_signed?(subject)
    end

    test "a disabled non-enforcing runner doesn't keep the fleet from reading signed-only" do
      {_user, account, subject} = owner_subject_fixture()

      _signed =
        runner_fixture(account_id: account.id, enforce_signatures: true, connected?: false)

      plain = runner_fixture(account_id: account.id, connected?: false)
      {:ok, _} = Runners.disable_runner(plain, subject)

      assert Runners.fleet_all_signed?(subject)
    end

    test "is account-scoped — account B's enforcing fleet doesn't make account A signed" do
      {_user_a, _account_a, subject_a} = owner_subject_fixture()
      account_b = account_fixture()
      _r = runner_fixture(account_id: account_b.id, enforce_signatures: true, connected?: false)

      refute Runners.fleet_all_signed?(subject_a)
    end

    test "false (no badge) for a subject without view_runners" do
      {_owner, account, _owner_subject} = owner_subject_fixture()
      _r = runner_fixture(account_id: account.id, enforce_signatures: true, connected?: false)
      no_view = %Emisar.Auth.Subject{account: account, role: :runner, permissions: MapSet.new()}

      refute Runners.fleet_all_signed?(no_view)
    end
  end

  describe "connection state & presence" do
    test "connection_state/1 maps online / disabled / pending / offline" do
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
    test "connection_state/1 stays :online regardless of last_heartbeat_at age (no :stale)" do
      ancient = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert Runners.connection_state(%Runner{online?: true, last_heartbeat_at: ancient}) ==
               :online

      # A nil heartbeat on a live socket is still :online, not a derived stale state.
      assert Runners.connection_state(%Runner{online?: true, last_heartbeat_at: nil}) == :online
    end

    test "list/fetch decorate online?, action_load + last heartbeat from presence" do
      {account, _user, subject} = account_with_owner_subject()
      runner = runner_fixture(account_id: account.id, connected?: true)
      {:ok, _ref} = Runners.record_heartbeat(account.id, runner.id, 5)

      {:ok, fetched} = Runners.fetch_runner_by_id(runner.id, subject)
      assert fetched.online?
      assert fetched.action_load == 5
      assert %DateTime{} = fetched.last_heartbeat_at

      assert {:ok, [listed], _} = Runners.list_runners_for_account(subject)
      assert listed.online?
      assert listed.action_load == 5
    end

    test "presence is account-scoped — another account never sees the runner online" do
      account_a = account_fixture()
      account_b = account_fixture()
      runner = runner_fixture(account_id: account_a.id, connected?: true)

      assert Runners.online?(account_a.id, runner.id)
      refute Runners.online?(account_b.id, runner.id)
      assert Runners.connection_metas(account_b.id) == %{}
    end

    test "status filter resolves each connection state via presence ids" do
      {account, _user, subject} = account_with_owner_subject()
      topic = Emisar.Runners.Presence.topic(account.id)

      _online = runner_fixture(account_id: account.id, name: "r-online", connected?: true)
      _pending = runner_fixture(account_id: account.id, name: "r-pending", connected?: false)

      # Connected then dropped from presence = "disconnected": last_connected_at
      # is set but the socket is no longer live.
      disc = runner_fixture(account_id: account.id, name: "r-disc", connected?: true)
      :ok = Emisar.Runners.Presence.untrack(self(), topic, disc.id)

      disabled = runner_fixture(account_id: account.id, name: "r-disabled", connected?: false)
      {:ok, _} = Runners.disable_runner(disabled, subject)

      assert filter_names(subject, "connected") == ["r-online"]
      assert filter_names(subject, "disconnected") == ["r-disc"]
      assert filter_names(subject, "pending") == ["r-pending"]
      assert filter_names(subject, "disabled") == ["r-disabled"]
    end
  end

  describe "signature enforcement" do
    test "apply_state sets enforce_signatures when the runner advertises it" do
      runner = runner_fixture()
      refute runner.enforce_signatures

      {:ok, updated} = Runners.apply_state(runner, %{"enforce_signatures" => true})
      assert updated.enforce_signatures
    end

    test "apply_state clears enforce_signatures when a later advertisement omits it" do
      runner = runner_fixture(enforce_signatures: true)
      assert runner.enforce_signatures

      # The latest advertisement is authoritative: a reconnect that doesn't
      # advertise enforcement (the toggle flipped off in config) clears it.
      {:ok, updated} = Runners.apply_state(runner, %{"hostname" => "h"})
      refute updated.enforce_signatures
    end

    test "runner_enforces_signatures?/2 is account-scoped" do
      account_a = account_fixture()
      account_b = account_fixture()
      runner = runner_fixture(account_id: account_a.id, enforce_signatures: true)

      assert Runners.runner_enforces_signatures?(runner.id, account_a.id)
      refute Runners.runner_enforces_signatures?(runner.id, account_b.id)
    end

    test "runner_enforces_signatures?/2 is false for a non-enforcing runner" do
      runner = runner_fixture()
      refute Runners.runner_enforces_signatures?(runner.id, runner.account_id)
    end
  end

  describe "fetch_runner_by_name/3" do
    test "fetches a non-deleted runner by its account-unique name" do
      {_user, account, subject} = owner_subject_fixture()
      runner = runner_fixture(account_id: account.id, name: "host-1")

      assert {:ok, fetched} = Runners.fetch_runner_by_name("host-1", subject)
      assert fetched.id == runner.id
    end

    test "not_found for an unknown name" do
      {_user, _account, subject} = owner_subject_fixture()
      assert {:error, :not_found} = Runners.fetch_runner_by_name("nope", subject)
    end

    test "cross-account: a name in another account doesn't resolve" do
      {_user_a, _account_a, subject_a} = owner_subject_fixture()
      account_b = account_fixture()
      _runner = runner_fixture(account_id: account_b.id, name: "host-b")

      assert {:error, :not_found} = Runners.fetch_runner_by_name("host-b", subject_a)
    end

    test "denial: a subject without view_runners is unauthorized" do
      {_owner, account, _owner_subject} = owner_subject_fixture()
      _runner = runner_fixture(account_id: account.id, name: "host-1")
      no_view = %Emisar.Auth.Subject{account: account, role: :runner, permissions: MapSet.new()}

      assert {:error, :unauthorized} = Runners.fetch_runner_by_name("host-1", no_view)
    end
  end

  describe "list_runners_for_account/2" do
    test "filters by account, group, and status" do
      {account, _user, subject} = account_with_owner_subject()
      other_account = account_fixture()

      _ = runner_fixture(account_id: account.id, group: "web", connected?: true)
      _ = runner_fixture(account_id: account.id, group: "db", connected?: false)
      _ = runner_fixture(account_id: other_account.id, group: "web")

      assert {:ok, list, _} = Runners.list_runners_for_account(subject)
      assert length(list) == 2
      assert {:ok, list, _} = Runners.list_runners_for_account(subject, group: "web")
      assert length(list) == 1

      # connected? tracks presence from this process, so the "connected"
      # filter resolves the online id set and returns just that runner.
      assert {:ok, list, _} = Runners.list_runners_for_account(subject, status: "connected")
      assert length(list) == 1
    end
  end

  describe "list_all_runners_for_account/1" do
    test "returns every runner — no pagination cap — decorated + account-scoped" do
      {account, _user, subject} = account_with_owner_subject()

      # 40 runners — past the paginator's 35-row default page.
      for _ <- 1..40, do: runner_fixture(account_id: account.id, connected?: false)

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
  end

  describe "auth keys from a fixed raw secret (seed bootstrap shape)" do
    test "the supplied raw secret round-trips through peek_auth_key_by_secret" do
      account = account_fixture()
      user = user_fixture()
      raw = "emkey-auth-dev-fixed-bootstrap-DO-NOT-USE-IN-PROD"

      key = auth_key_with_secret_fixture(raw, account.id, user.id, %{reusable: true})

      assert key.key_prefix == String.slice(raw, 0, 27)
      # The lookup round-trips: presenting the raw secret resolves to
      # the same record. This is what makes the docker-compose seeder +
      # runner handoff work without an out-of-band copy step — and what
      # pins the changeset's prefix size to Runners' mint size.
      assert %AuthKey{id: id} = Runners.peek_auth_key_by_secret(raw)
      assert id == key.id
    end
  end

  describe "mint_install_key/2" do
    test "stores an auto_generated_at timestamp" do
      {_account, _user, subject} = account_with_owner_subject()

      assert {:ok, raw, %AuthKey{} = key} = Runners.mint_install_key(subject)
      assert String.starts_with?(raw, "emkey-auth-")
      assert key.auto_generated_at != nil
      assert is_nil(key.last_used_at)
      assert AuthKey.auto_unused?(key)
    end

    test "auto-unused keys are hidden from list_auth_keys/1" do
      {_account, _user, subject} = account_with_owner_subject()

      {:ok, _, _} = Runners.mint_install_key(subject)
      {:ok, _, _} = Runners.mint_install_key(subject)

      # Both keys exist in DB; neither shows up in operator-facing list.
      assert Repo.aggregate(AuthKey, :count) == 2
      assert {:ok, [], _} = Runners.list_auth_keys(subject)

      # Manually-issued keys (no auto flag) still show.
      {:ok, _, manual} = Runners.create_auth_key(%{reusable: true}, subject)
      assert {:ok, [%AuthKey{id: id}], _} = Runners.list_auth_keys(subject)
      assert id == manual.id
    end

    test "list_auth_keys status filter hides or shows revoked keys" do
      {_account, _user, subject} = account_with_owner_subject()

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

    test "ring eviction caps the auto-unused set at the configured size" do
      {_account, _user, subject} = account_with_owner_subject()

      # Tiny cap so the test runs fast. Bypass grace by making it 0 so
      # the eviction query trims the moment we exceed the cap.
      for _ <- 1..5 do
        {:ok, _, _} = Runners.mint_install_key(subject, ring_cap: 3, eviction_grace_seconds: 0)
      end

      assert Repo.aggregate(AuthKey, :count) == 3
    end

    test "grace window protects fresh keys from eviction even past cap" do
      {_account, _user, subject} = account_with_owner_subject()

      # cap=2, but grace=60s means a burst of 5 mints in the same
      # second all survive (none are older than the grace floor).
      for _ <- 1..5 do
        {:ok, _, _} = Runners.mint_install_key(subject, ring_cap: 2, eviction_grace_seconds: 60)
      end

      assert Repo.aggregate(AuthKey, :count) == 5
    end

    test "does NOT touch other accounts' keys" do
      {_account, _user, subject} = account_with_owner_subject()
      {_other, _other_user, other_subject} = account_with_owner_subject()

      {:ok, _, other_key} = Runners.mint_install_key(other_subject)

      # Saturate this account's ring.
      for _ <- 1..10 do
        {:ok, _, _} = Runners.mint_install_key(subject, ring_cap: 2, eviction_grace_seconds: 0)
      end

      # `other`'s key is untouched.
      assert AuthKey.Query.all() |> AuthKey.Query.by_id(other_key.id) |> Repo.peek() != nil
    end
  end

  describe "register_via_auth_key/2 with auto-generated keys" do
    test "promotes an auto-generated key to permanent on first use" do
      {account, _user, subject} = account_with_owner_subject()
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
      _ = account
    end

    test "emits an auth_key.bound audit event with auto: true" do
      {_account, _user, subject} = account_with_owner_subject()
      {:ok, raw, _key} = Runners.mint_install_key(subject)

      {:ok, _runner, _token, _raw_token} =
        Runners.register_via_auth_key(raw, %{
          hostname: "demo",
          group: "demo",
          external_id: "ext-#{System.unique_integer([:positive])}"
        })

      events =
        Emisar.Audit.list_events(subject, page: [limit: 50])
        |> elem(1)

      bound = Enum.find(events, &(&1.event_type == "auth_key.bound"))
      assert bound != nil
      assert bound.payload["auto"] == true
    end
  end

  describe "enable_runner/2" do
    test "re-enables a disabled runner (clears disabled_at)" do
      {account, _user, subject} = account_with_owner_subject()
      runner = runner_fixture(account_id: account.id, connected?: false)
      {:ok, disabled} = Runners.disable_runner(runner, subject)
      assert disabled.disabled_at

      assert {:ok, enabled} = Runners.enable_runner(disabled, subject)
      assert is_nil(enabled.disabled_at)
    end

    test "a viewer can't enable a runner" do
      {account, _owner_user, owner} = account_with_owner_subject()
      runner = runner_fixture(account_id: account.id, connected?: false)
      {:ok, disabled} = Runners.disable_runner(runner, owner)

      viewer = user_fixture()
      _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
      viewer_subject = subject_for(viewer, account, role: :viewer)

      assert {:error, :unauthorized} = Runners.enable_runner(disabled, viewer_subject)
    end

    test "won't enable a runner from another account" do
      {account_a, _ua, owner_a} = account_with_owner_subject()
      {_account_b, _ub, owner_b} = account_with_owner_subject()
      runner = runner_fixture(account_id: account_a.id, connected?: false)
      {:ok, disabled} = Runners.disable_runner(runner, owner_a)

      assert {:error, :not_found} = Runners.enable_runner(disabled, owner_b)
    end

    test "refuses to enable past the plan limit (free = 3)" do
      {account, _user, subject} = account_with_owner_subject()
      to_disable = runner_fixture(account_id: account.id, connected?: false)
      {:ok, disabled} = Runners.disable_runner(to_disable, subject)

      # Fill all three active slots while it's disabled, then try to claim a
      # fourth by re-enabling.
      for _ <- 1..3, do: runner_fixture(account_id: account.id, connected?: false)

      assert {:error, :over_limit, "free", 3} = Runners.enable_runner(disabled, subject)
    end
  end

  describe "plan-limit runner count (Billing.check_limit/2)" do
    test "deleted runners don't count toward the limit" do
      {account, _user, subject} = account_with_owner_subject()
      r1 = runner_fixture(account_id: account.id, connected?: false)
      runner_fixture(account_id: account.id, connected?: false)
      runner_fixture(account_id: account.id, connected?: false)

      assert {:error, :over_limit, "free", 3} = Billing.check_limit(account, :runners)

      {:ok, _} = Runners.delete_runner(r1, subject)

      assert :ok = Billing.check_limit(account, :runners)
      assert {:ok, %{runner_count: 2}} = Billing.billing_summary(account, subject)
    end

    test "disabled runners don't count toward the limit" do
      {account, _user, subject} = account_with_owner_subject()
      r1 = runner_fixture(account_id: account.id, connected?: false)
      runner_fixture(account_id: account.id, connected?: false)
      runner_fixture(account_id: account.id, connected?: false)

      assert {:error, :over_limit, "free", 3} = Billing.check_limit(account, :runners)

      {:ok, _} = Runners.disable_runner(r1, subject)
      assert :ok = Billing.check_limit(account, :runners)
    end

    test "an unknown/legacy plan name falls back to free limits, not a crash" do
      {account, _user, _subject} = account_with_owner_subject()
      # A subscription plan no longer in Billing.plans() (legacy/renamed)
      # used to raise BadMapError on Map.get(nil, :runners_limit). It must
      # fall back to the free plan's limits instead. Plan is read from the
      # subscription now, and Paddle owns the value space — so an unknown
      # name can legitimately persist and must degrade gracefully.
      subscription_fixture(account, "legacy-pro")

      assert :ok = Billing.check_limit(account, :runners)

      for _ <- 1..3, do: runner_fixture(account_id: account.id, connected?: false)
      assert {:error, :over_limit, "legacy-pro", 3} = Billing.check_limit(account, :runners)
    end

    test "a past_due account keeps full plan limits — status never gates registration" do
      # account_plan/1 is status-agnostic, so a Team account whose subscription
      # lapsed to past_due still resolves to the Team cap (100) and registers a
      # runner under it. Billing status is advisory (banners), never an entitlement
      # gate — register_via_auth_key only blocks on the runner cap.
      account = account_fixture()
      subscription_fixture(account, "team", status: "past_due")
      user = user_fixture()

      assert Billing.account_plan(account) == "team"
      # Two runners on a Team plan is well under the cap → check_limit is :ok.
      _ = runner_fixture(account_id: account.id)
      _ = runner_fixture(account_id: account.id)
      assert :ok = Billing.check_limit(account, :runners)

      {raw, _key} =
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

      assert {:ok, %Runner{}, _, _} =
               Runners.register_via_auth_key(raw, %{external_id: "ext-pastdue", group: "g"})
    end

    test "member invites are uncapped — inviting past members_limit succeeds" do
      # Free caps members at 1, but the invite path has NO Billing.check_limit(:members)
      # (accounts.ex:1176) — seats are a deliberate growth lever, the meter is advisory.
      # The account starts at its 1-member ceiling (the owner); inviting still succeeds.
      {account, _owner, subject} = account_with_owner_subject()
      assert Billing.account_plan(account) == "free"
      assert Emisar.Accounts.count_memberships(account.id) == 1

      assert {:ok, %{membership: %Emisar.Accounts.Membership{}}} =
               Emisar.Accounts.invite_user_to_account("invitee@example.test", "operator", subject)

      # Over the free members_limit of 1 now, yet a second invite still goes through.
      assert {:ok, %{membership: %Emisar.Accounts.Membership{}}} =
               Emisar.Accounts.invite_user_to_account(
                 "invitee2@example.test",
                 "operator",
                 subject
               )

      assert Emisar.Accounts.count_memberships(account.id) == 3
    end

    test "check_limit/2 is account-scoped with no Subject (pre-auth bootstrap contract)" do
      # The runner-bootstrap path (register_via_auth_key/2) calls check_limit
      # BEFORE any Subject exists, so the contract is `(account, resource)` —
      # account-scoped, no Subject argument. Driving it with just an account proves
      # it needs no authz carrier; arity-2 (not 3) locks the no-Subject signature.
      account = account_fixture()
      refute function_exported?(Billing, :check_limit, 3)
      assert function_exported?(Billing, :check_limit, 2)

      assert :ok = Billing.check_limit(account, :runners)
      assert :ok = Billing.check_limit(account, :members)
    end

    test "count_billable_runners/1 is a COUNT (an integer), not a fetch of rows" do
      # count_billable_runners/1 (and count_memberships/1) return a single integer
      # from a SELECT count(*) aggregate — never a list of loaded rows into memory.
      # Adding a billable runner moves the count by exactly one.
      account = account_fixture()

      assert Runners.count_billable_runners(account.id) == 0
      assert is_integer(Runners.count_billable_runners(account.id))

      _ = runner_fixture(account_id: account.id, connected?: false)
      assert Runners.count_billable_runners(account.id) == 1

      # count_memberships/1 is likewise a COUNT — a fresh account has its owner only.
      assert Emisar.Accounts.count_memberships(account.id) == 0
      assert is_integer(Emisar.Accounts.count_memberships(account.id))
    end
  end

  describe "apply_state/2 — group" do
    test "a config runner.group rename propagates on the next reconnect" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id, group: "old-group")

      {:ok, updated} =
        Runners.apply_state(runner, %{
          "group" => "new-group",
          "hostname" => "h1",
          "packs" => %{}
        })

      assert updated.group == "new-group"
    end

    test "keeps the existing group when the payload's group is blank or missing" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id, group: "keep-me")

      assert {:ok, blank} = Runners.apply_state(runner, %{"group" => ""})
      assert blank.group == "keep-me"

      assert {:ok, missing} = Runners.apply_state(runner, %{"hostname" => "h2"})
      assert missing.group == "keep-me"
    end
  end

  describe "Authorizer.for_subject runner-scoping" do
    test "a runner subject sees only its own runner row, not its account peers" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)
      _peer = runner_fixture(account_id: account.id)

      runner_subject = Emisar.Auth.Subject.for_runner(runner, account)

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
      assert Runners.Authorizer.for_subject(query, %Emisar.Auth.Subject{}) == query
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
      never = fn -> runner_fixture(connected?: false) end

      # never-connected: no connection timestamps, across two accounts.
      _ = never.()
      _ = runner_fixture(connected?: false, account_id: account_fixture().id)

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

  # Stamp a runner's durable connection-record columns directly — `register/0`
  # leaves a fresh runner never-connected, so the connection-state tests set them.
  defp put_connection(runner, fields),
    do: runner |> Ecto.Changeset.change(fields) |> Repo.update!()

  defp viewer_subject_for(account) do
    viewer = user_fixture()
    _ = membership_fixture(account_id: account.id, user_id: viewer.id, role: "viewer")
    subject_for(viewer, account, role: :viewer)
  end

  # §7: every Subject-gated management write must reject a role lacking its
  # permission (→ :unauthorized) and an entity in another account. The
  # runner/auth-key writes scope via fetch_and_update, so cross-account is
  # :not_found; enable_runner's pair lives in its own describe — these complete
  # the set for create/disable/delete runner + create/mint/revoke auth keys.
  describe "management-write authorization (§7 denial + cross-account)" do
    test "create_runner: a viewer (no manage_runners) is refused" do
      account = account_fixture()

      assert {:error, :unauthorized} =
               Runners.create_runner(
                 %{"name" => "v-1", "group" => "g"},
                 viewer_subject_for(account)
               )
    end

    test "disable_runner: a viewer (no manage_runners) is refused" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

      assert {:error, :unauthorized} = Runners.disable_runner(runner, viewer_subject_for(account))
    end

    test "disable_runner: won't touch a runner in another account" do
      {account_a, _ua, _owner_a} = account_with_owner_subject()
      {_account_b, _ub, owner_b} = account_with_owner_subject()
      runner_a = runner_fixture(account_id: account_a.id)

      assert {:error, :not_found} = Runners.disable_runner(runner_a, owner_b)
    end

    test "delete_runner: a viewer (no manage_runners) is refused" do
      account = account_fixture()
      runner = runner_fixture(account_id: account.id)

      assert {:error, :unauthorized} = Runners.delete_runner(runner, viewer_subject_for(account))
    end

    test "delete_runner: won't touch a runner in another account" do
      {account_a, _ua, _owner_a} = account_with_owner_subject()
      {_account_b, _ub, owner_b} = account_with_owner_subject()
      runner_a = runner_fixture(account_id: account_a.id)

      assert {:error, :not_found} = Runners.delete_runner(runner_a, owner_b)
    end

    test "create_auth_key: a viewer (no manage_auth_keys) is refused" do
      account = account_fixture()

      assert {:error, :unauthorized} =
               Runners.create_auth_key(%{reusable: true}, viewer_subject_for(account))
    end

    test "mint_install_key: a viewer (no issue_install_key) is refused" do
      account = account_fixture()

      assert {:error, :unauthorized} = Runners.mint_install_key(viewer_subject_for(account))
    end

    test "revoke_auth_key: a viewer (no manage_auth_keys) is refused" do
      {account, _user, owner} = account_with_owner_subject()
      {:ok, _raw, key} = Runners.create_auth_key(%{reusable: true}, owner)

      assert {:error, :unauthorized} = Runners.revoke_auth_key(key, viewer_subject_for(account))
    end

    test "revoke_auth_key: won't touch an auth key in another account" do
      {_account_a, _ua, owner_a} = account_with_owner_subject()
      {_account_b, _ub, owner_b} = account_with_owner_subject()
      {:ok, _raw, key_a} = Runners.create_auth_key(%{reusable: true}, owner_a)

      assert {:error, :not_found} = Runners.revoke_auth_key(key_a, owner_b)
    end
  end
end
