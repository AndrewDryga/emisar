defmodule Emisar.ApiKeysTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{ApiKeys, Repo}
  alias Emisar.ApiKeys.ApiKey

  describe "create_key/3" do
    test "returns raw + persisted key" do
      account = account_fixture()
      user = user_fixture()

      assert {:ok, raw, %ApiKey{} = key} =
               ApiKeys.create_key(account.id, user.id, %{
                 name: "ci",
                 scopes: ["actions:read"]
               })

      assert String.starts_with?(raw, "emk-")
      assert key.account_id == account.id
      assert key.created_by_id == user.id
      assert is_binary(key.key_hash)
      assert is_binary(key.key_prefix)
    end

    test "rejects unknown scopes" do
      account = account_fixture()
      user = user_fixture()

      assert {:error, cs} =
               ApiKeys.create_key(account.id, user.id, %{
                 name: "bad",
                 scopes: ["actions:nuclear-launch"]
               })

      assert "has an invalid entry" in errors_on(cs).scopes
    end
  end

  describe "find_by_secret/1" do
    test "returns the key for a valid raw secret + bumps last_used_at" do
      {raw, key} = api_key_fixture()
      refute key.last_used_at

      assert %ApiKey{id: id, last_used_at: ts} = ApiKeys.find_by_secret(raw)
      assert id == key.id
      assert %DateTime{} = ts
    end

    test "returns nil for garbage" do
      refute ApiKeys.find_by_secret("not-a-key")
      refute ApiKeys.find_by_secret("")
    end

    test "returns nil after the key is revoked" do
      {raw, key} = api_key_fixture()
      user = user_fixture()
      {:ok, _} = ApiKeys.revoke(key, user.id)

      refute ApiKeys.find_by_secret(raw)
    end
  end

  describe "revoke/2" do
    test "marks revoked_at" do
      {_raw, key} = api_key_fixture()
      user = user_fixture()

      assert {:ok, %ApiKey{revoked_at: %DateTime{}, revoked_by_id: id}} =
               ApiKeys.revoke(key, user.id)

      assert id == user.id
      assert Repo.reload!(key).revoked_at
    end
  end
end
