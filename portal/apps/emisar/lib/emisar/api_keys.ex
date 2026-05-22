defmodule Emisar.ApiKeys do
  @moduledoc """
  Programmatic-access keys. Issued in the UI; presented as
  `Authorization: Bearer <key>` on the MCP HTTP endpoint.
  """

  import Ecto.Query
  alias Emisar.Repo
  alias Emisar.ApiKeys.ApiKey

  @prefix_size 12
  @secret_size 32

  def list_for_account(account_id) do
    from(k in ApiKey, where: k.account_id == ^account_id, order_by: [desc: k.inserted_at])
    |> Repo.all()
  end

  def get_key(account_id, id) do
    from(k in ApiKey, where: k.account_id == ^account_id and k.id == ^id)
    |> Repo.one()
  end

  def create_key(account_id, user_id, attrs) do
    raw = generate_secret()
    prefix = String.slice(raw, 0, @prefix_size)
    hash = :crypto.hash(:sha256, raw)

    changeset =
      %ApiKey{}
      |> ApiKey.create_changeset(Map.merge(attrs, %{account_id: account_id, created_by_id: user_id}))
      |> Ecto.Changeset.put_change(:key_prefix, prefix)
      |> Ecto.Changeset.put_change(:key_hash, hash)

    case Repo.insert(changeset) do
      {:ok, key} ->
        Emisar.Audit.log(account_id, "api_key.created",
          actor_kind: "user",
          actor_id: user_id,
          subject_kind: "api_key",
          subject_id: key.id,
          subject_label: key.name,
          payload: %{prefix: key.key_prefix, scopes: key.scopes}
        )

        {:ok, raw, key}

      err ->
        err
    end
  end

  def revoke(%ApiKey{} = k, by_user_id) do
    case k |> ApiKey.revoke_changeset(by_user_id) |> Repo.update() do
      {:ok, key} = ok ->
        Emisar.Audit.log(key.account_id, "api_key.revoked",
          actor_kind: "user",
          actor_id: by_user_id,
          subject_kind: "api_key",
          subject_id: key.id,
          subject_label: key.name,
          payload: %{prefix: key.key_prefix}
        )

        ok

      err ->
        err
    end
  end

  def find_by_secret(raw) when is_binary(raw) do
    if String.length(raw) < @prefix_size do
      nil
    else
      prefix = String.slice(raw, 0, @prefix_size)
      hash = :crypto.hash(:sha256, raw)

      with %ApiKey{} = key <- Repo.get_by(ApiKey, key_prefix: prefix),
           true <- secure_compare(key.key_hash, hash),
           true <- ApiKey.usable?(key) do
        Repo.update!(ApiKey.usage_changeset(key))
      else
        _ -> nil
      end
    end
  end

  defp generate_secret do
    "emk-" <> (:crypto.strong_rand_bytes(@secret_size) |> Base.url_encode64(padding: false))
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
    do: :crypto.hash_equals(a, b)

  defp secure_compare(_, _), do: false
end
