defmodule Emisar.RunnersTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Runners
  alias Emisar.Runners.{Runner, AuthKey, Token}
  alias Emisar.Repo

  defp account_with_owner_subject do
    user = user_fixture()
    account = account_fixture()
    _ = membership_fixture(account_id: account.id, user_id: user.id, role: "owner")
    subject = subject_for(user, account, role: :owner)
    {account, user, subject}
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

    test "a different external_id with the same name creates a second runner" do
      # Names are display-only and may repeat — a fresh install / different
      # machine gets a new external_id and registers as its own runner.
      account = account_fixture()
      user = user_fixture()

      {raw, _key} =
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

      base = %{hostname: "samehost", group: "g"}

      assert {:ok, %Runner{id: id1, name: "samehost"}, _, _} =
               Runners.register_via_auth_key(raw, Map.put(base, :external_id, "ext-a"))

      assert {:ok, %Runner{id: id2, name: "samehost"}, _, _} =
               Runners.register_via_auth_key(raw, Map.put(base, :external_id, "ext-b"))

      refute id1 == id2
    end

    test "registers without an external_id (no crash) — each call a fresh runner" do
      # An older runner that doesn't send external_id: the server mints a
      # fresh UUID per call. It must register cleanly (no 500), even though
      # that means a new row each time.
      account = account_fixture()
      user = user_fixture()

      {raw, _key} =
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

      attrs = %{hostname: "no-id-host", group: "g"}

      assert {:ok, %Runner{id: id1}, _, _} = Runners.register_via_auth_key(raw, attrs)
      assert {:ok, %Runner{id: id2}, _, _} = Runners.register_via_auth_key(raw, attrs)

      refute id1 == id2
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

  describe "verify_runner_token/1" do
    test "returns {:ok, token, runner} for a valid raw token" do
      account = account_fixture()
      user = user_fixture()

      {raw, _key} =
        auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

      {:ok, _agent, _token, raw_token} = Runners.register_via_auth_key(raw, %{group: "demo"})

      assert {:ok, %Token{} = tok, %Runner{}} = Runners.verify_runner_token(raw_token)
      # `verify_runner_token` bumps last_used_at server-side; reload to observe.
      assert %Token{last_used_at: %DateTime{}} = Repo.reload!(tok)
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

  describe "mark_connected / mark_disconnected" do
    test "struct-based mark_connected updates status + broadcasts" do
      runner = runner_fixture(connected?: false)
      Emisar.PubSub.subscribe_account_runners(runner.account_id)

      assert {:ok, %Runner{status: "connected", last_connected_at: %DateTime{}}} =
               Runners.mark_connected(runner)

      assert_receive {:runner_connected, %Runner{}}, 500
    end

    test "id-based mark_disconnected returns :not_found for an unknown id" do
      assert {:error, :not_found} = Runners.mark_disconnected(Ecto.UUID.generate(), "gone")
    end

    test "id-based mark_disconnected updates the runner + broadcasts" do
      runner = runner_fixture()
      Emisar.PubSub.subscribe_account_runners(runner.account_id)

      assert {:ok, %Runner{status: "disconnected", last_disconnect_reason: "shutdown"}} =
               Runners.mark_disconnected(runner.id, "shutdown")

      assert_receive {:runner_disconnected, %Runner{}}, 500
    end
  end

  describe "record_heartbeat/2" do
    test "updates last_heartbeat_at + action_load" do
      runner = runner_fixture()

      assert {:ok, %Runner{last_heartbeat_at: ts, action_load: 7}} =
               Runners.record_heartbeat(runner, 7)

      assert %DateTime{} = ts
    end

    test "id-based variant returns :not_found for unknown id" do
      assert {:error, :not_found} = Runners.record_heartbeat(Ecto.UUID.generate(), 0)
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

      # connected? defaults to true → status="connected"
      assert {:ok, list, _} = Runners.list_runners_for_account(subject, status: "connected")
      assert length(list) == 1
    end
  end

  describe "create_auth_key_with_secret/4" do
    test "inserts a key whose hash matches the supplied raw secret" do
      account = account_fixture()
      user = user_fixture()
      raw = "emkey-auth-dev-fixed-bootstrap-DO-NOT-USE-IN-PROD"

      assert {:ok, %AuthKey{} = key} =
               Runners.create_auth_key_with_secret(raw, account.id, user.id, %{reusable: true})

      assert key.key_prefix == String.slice(raw, 0, 27)
      # And the lookup round-trips: presenting the raw secret resolves
      # to the same record. This is what makes the docker-compose
      # seeder + runner handoff work without an out-of-band copy step.
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
      {account, _user, subject} = account_with_owner_subject()
      {:ok, raw, _key} = Runners.mint_install_key(subject)

      {:ok, _runner, _token, _raw_token} =
        Runners.register_via_auth_key(raw, %{
          hostname: "demo",
          group: "demo",
          external_id: "ext-#{System.unique_integer([:positive])}"
        })

      events =
        Emisar.Audit.list_events(Emisar.Auth.Subject.system(account), page: [limit: 50])
        |> elem(1)

      bound = Enum.find(events, &(&1.event_type == "auth_key.bound"))
      assert bound != nil
      assert bound.payload["auto"] == true
    end
  end
end
