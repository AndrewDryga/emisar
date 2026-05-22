defmodule Emisar.RunnersTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.Runners
  alias Emisar.Runners.{Runner, AuthKey, Token}
  alias Emisar.Repo

  describe "create_auth_key/3" do
    test "returns a raw secret + persists the hash with a prefix" do
      account = account_fixture()
      user = user_fixture()

      assert {:ok, raw, %AuthKey{} = key} =
               Runners.create_auth_key(account.id, user.id, %{description: "for dev"})

      assert String.starts_with?(raw, "emkey-auth-")
      assert key.account_id == account.id
      assert key.created_by_id == user.id
      assert is_binary(key.key_hash)
      assert key.description == "for dev"
    end
  end

  describe "find_auth_key_by_secret/1" do
    test "returns the key for a valid secret" do
      account = account_fixture()
      user = user_fixture()
      {:ok, raw, %AuthKey{id: id}} = Runners.create_auth_key(account.id, user.id, %{reusable: true})

      assert %AuthKey{id: ^id} = Runners.find_auth_key_by_secret(raw)
    end

    test "returns nil for a revoked key" do
      account = account_fixture()
      user = user_fixture()
      {:ok, raw, key} = Runners.create_auth_key(account.id, user.id, %{reusable: true})
      {:ok, _} = Runners.revoke_auth_key(key, user.id)

      refute Runners.find_auth_key_by_secret(raw)
    end

    test "returns nil for an expired key" do
      account = account_fixture()
      user = user_fixture()
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      {:ok, raw, _key} =
        Runners.create_auth_key(account.id, user.id, %{reusable: true, expires_at: past})

      refute Runners.find_auth_key_by_secret(raw)
    end

    test "returns nil for a single-use key after first use" do
      account = account_fixture()
      user = user_fixture()
      {:ok, raw, key} = Runners.create_auth_key(account.id, user.id, %{reusable: false})

      # First use bumps usage; second lookup should miss.
      assert %AuthKey{id: id} = Runners.find_auth_key_by_secret(raw)
      assert id == key.id

      {:ok, _} = key |> AuthKey.usage_changeset() |> Repo.update()
      refute Runners.find_auth_key_by_secret(raw)
    end

    test "returns nil for garbage input" do
      refute Runners.find_auth_key_by_secret("not-a-key")
      refute Runners.find_auth_key_by_secret("")
    end
  end

  describe "register_via_auth_key/2" do
    test "mints an runner + token on success" do
      account = account_fixture()
      user = user_fixture()
      {raw, _key} = auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

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

    test "returns :over_limit when the plan cap is exceeded" do
      # `free` plan caps runners at 3.
      account = account_fixture(plan: "free")
      user = user_fixture()

      _ = runner_fixture(account_id: account.id)
      _ = runner_fixture(account_id: account.id)
      _ = runner_fixture(account_id: account.id)

      {raw, _key} = auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)

      assert {:error, :over_limit, "free", 3} =
               Runners.register_via_auth_key(raw, %{group: "demo"})
    end

    test "returns :auth_key_invalid for an unknown raw secret" do
      assert {:error, :auth_key_invalid} =
               Runners.register_via_auth_key("emkey-auth-garbage", %{})
    end

    @tag :async_db_unsafe
    test "single-use key under concurrent attempts: exactly one succeeds" do
      # The race the atomic-claim defends against: two callers both
      # observe uses_count = 0 and both try to register. With the old
      # serial "select then update" implementation, both succeed and
      # we end up with two runners from a single-use key.
      account = account_fixture()
      user = user_fixture()
      {raw, _key} = auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: false)

      # Use Task.async + a barrier to start them as close together as
      # we can. Different external_ids so both would create separate
      # runners if both calls slip through.
      barrier = Task.async(fn -> :ok end)
      _ = Task.await(barrier)

      attempt = fn idx ->
        Runners.register_via_auth_key(raw, %{
          hostname: "demo-#{idx}",
          group: "demo",
          external_id: "ext-#{idx}-#{System.unique_integer([:positive])}"
        })
      end

      results =
        1..8
        |> Enum.map(fn i -> Task.async(fn -> attempt.(i) end) end)
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
      {raw, _key} = auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)
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
      user = user_fixture()
      {raw, _key} = auth_key_fixture(account_id: account.id, created_by_id: user.id, reusable: true)
      {:ok, runner, _token, raw_token} = Runners.register_via_auth_key(raw, %{group: "demo"})

      {:ok, _} = Runners.disable_runner(runner)

      assert {:error, :token_invalid} = Runners.verify_runner_token(raw_token)
    end
  end

  describe "mark_connected / mark_disconnected" do
    test "struct-based mark_connected updates status + broadcasts" do
      runner = runner_fixture(connected?: false)
      Emisar.PubSub.subscribe_account_runners(runner.account_id)

      assert {:ok, %Runner{status: "connected", last_connected_at: %DateTime{}}} =
               Runners.mark_connected(runner, %{})

      assert_receive {:runner_connected, %Runner{}}
    end

    test "id-based mark_disconnected returns :not_found for an unknown id" do
      assert {:error, :not_found} = Runners.mark_disconnected(Ecto.UUID.generate(), "gone")
    end

    test "id-based mark_disconnected updates the runner + broadcasts" do
      runner = runner_fixture()
      Emisar.PubSub.subscribe_account_runners(runner.account_id)

      assert {:ok, %Runner{status: "disconnected", last_disconnect_reason: "shutdown"}} =
               Runners.mark_disconnected(runner.id, "shutdown")

      assert_receive {:runner_disconnected, %Runner{}}
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
      account = account_fixture()
      other_account = account_fixture()

      _ = runner_fixture(account_id: account.id, group: "web", connected?: true)
      _ = runner_fixture(account_id: account.id, group: "db", connected?: false)
      _ = runner_fixture(account_id: other_account.id, group: "web")

      assert length(Runners.list_runners_for_account(account.id)) == 2
      assert length(Runners.list_runners_for_account(account.id, group: "web")) == 1

      # connected? defaults to true → status="connected"
      assert length(Runners.list_runners_for_account(account.id, status: "connected")) == 1
    end
  end
end
