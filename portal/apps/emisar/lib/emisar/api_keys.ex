defmodule Emisar.ApiKeys do
  # Per-account ring cap for auto-generated, unused API keys. Agents
  # page mounts mint into the ring; when capacity is exceeded, the
  # oldest auto-unused entry is evicted. Declared above the moduledoc
  # so the cap can be interpolated there.
  @quick_ring_cap 42

  @moduledoc """
  Programmatic-access keys. Issued in the UI; presented as
  `Authorization: Bearer <key>` on the MCP HTTP endpoint.

  Auto-generated keys are minted on every Agents page load so the
  snippet renders pre-filled; they're hidden from operator-facing
  lists until an LLM actually authenticates with one. Ring-evicted at
  #{@quick_ring_cap} unused entries per account.
  """

  alias Emisar.{Audit, Auth, Repo}
  alias Emisar.ApiKeys.{ApiKey, Authorizer}
  alias Emisar.Auth.Subject

  # 4 chars for "emk-" + 8 random chars => 12-char prefix.
  @prefix_size 12
  @secret_size 32

  # Keys minted within this window are protected from eviction even
  # when the ring is full — buffer for the "user copied the snippet →
  # LLM makes its first MCP call" gap.
  @quick_eviction_grace_seconds 60

  # -- Reads -----------------------------------------------------------

  @doc """
  Lists keys visible to operators — hides auto-generated, never-used
  ones. `:created_by` is preloaded so the UI can render the creator's
  email without an N+1.
  """
  def list_api_keys_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_api_keys_permission()
           ) do
      ApiKey.Query.visible_to_operators()
      |> ApiKey.Query.ordered_by_recent()
      |> Authorizer.for_subject(subject)
      |> Repo.list(ApiKey.Query, Keyword.put_new(opts, :preload, :created_by))
    end
  end

  def fetch_api_key_by_id(id, %Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_api_keys_permission()
           ),
         true <- Repo.valid_uuid?(id) do
      ApiKey.Query.not_deleted()
      |> ApiKey.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(ApiKey.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  # -- Mutations -------------------------------------------------------

  def create_key(attrs, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_api_keys_permission()
           ) do
      account_id = account.id
      user_id = actor_id(subject)
      {raw, prefix, hash} = mint_secret()
      changeset = ApiKey.Changeset.create(account_id, user_id, prefix, hash, attrs)

      case Repo.insert(changeset) do
        {:ok, key} ->
          Audit.log(account_id, "api_key.created",
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
  end

  @doc """
  Mints a fresh API key for the Agents page's pre-filled snippet,
  marks it auto-generated (invisible until an LLM uses it), and evicts
  the oldest auto-unused key beyond the per-account ring cap of
  #{@quick_ring_cap}. All in one transaction.

  Returns `{:ok, raw_secret, key}`. No audit log on mint — auto-gen
  is noise. Once an LLM authenticates with the key, `usage/1` clears
  the auto flag and `api_key.bound` is logged.

  Sensible defaults are baked in: scopes `actions:read` +
  `actions:execute`, all runners. Operators wanting custom scopes use
  the "Custom key" form, which calls `create_key/2` instead.
  """
  def mint_quick_key(%Subject{account: account} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.issue_quick_key_permission()
           ) do
      account_id = account.id
      user_id = actor_id(subject)
      cap = opts[:ring_cap] || @quick_ring_cap
      grace_s = opts[:eviction_grace_seconds] || @quick_eviction_grace_seconds
      name = opts[:name] || "Quick connect (auto)"

      {raw, prefix, hash} = mint_secret()

      Repo.transaction(fn ->
        {:ok, key} =
          ApiKey.Changeset.mint_quick(account_id, user_id, prefix, hash, %{name: name})
          |> Repo.insert()

        evict_quick_ring_overflow(account_id, cap, grace_s, key.auto_generated_at)
        {raw, key}
      end)
      |> case do
        {:ok, {raw, key}} -> {:ok, raw, key}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp evict_quick_ring_overflow(account_id, cap, grace_seconds, now) do
    protected_floor = DateTime.add(now, -grace_seconds, :second)

    ApiKey.Query.evictable_quick_overflow(account_id, cap, protected_floor)
    |> Repo.delete_all()
  end

  def revoke_api_key(%ApiKey{} = key, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_api_keys_permission()
           ),
         :ok <- ensure_key_in_subject_account(key, subject) do
      by_user_id = actor_id(subject)

      case key |> ApiKey.Changeset.revoke(by_user_id) |> Repo.update() do
        {:ok, revoked} = ok ->
          Audit.log(revoked.account_id, "api_key.revoked",
            actor_kind: "user",
            actor_id: by_user_id,
            subject_kind: "api_key",
            subject_id: revoked.id,
            subject_label: revoked.name,
            payload: %{prefix: revoked.key_prefix}
          )

          ok

        err ->
          err
      end
    end
  end

  defp ensure_key_in_subject_account(%ApiKey{account_id: account_id}, %Subject{} = subject),
    do: Subject.ensure_in_account(subject, account_id)

  defdelegate actor_id(subject), to: Subject

  @doc """
  Peeks at the presented bearer token, resolving it to an `%ApiKey{}`.
  Bumps `last_used_at` and — if the key is auto-generated — clears the
  auto flag and audit-logs `api_key.bound`. Returns the updated struct
  or nil (`peek_*` per CLAUDE.md §1.1 — nil-or-struct credential
  lookup).

  Internal — called from the MCP controller's `:authenticate` plug
  before any Subject exists. The presented bearer IS the auth.
  """
  def peek_api_key_by_secret(raw) when is_binary(raw) do
    if String.length(raw) < @prefix_size do
      nil
    else
      prefix = String.slice(raw, 0, @prefix_size)
      hash = :crypto.hash(:sha256, raw)

      with %ApiKey{} = key <-
             ApiKey.Query.all() |> ApiKey.Query.by_key_prefix(prefix) |> Repo.peek(),
           true <- secure_compare(key.key_hash, hash),
           true <- ApiKey.usable?(key) do
        was_auto? = ApiKey.auto_unused?(key)
        updated = Repo.update!(ApiKey.Changeset.usage(key))

        if was_auto? do
          Audit.log(updated.account_id, "api_key.bound",
            actor_kind: "system",
            subject_kind: "api_key",
            subject_id: updated.id,
            subject_label: updated.name,
            payload: %{prefix: updated.key_prefix, auto: true}
          )
        end

        updated
      else
        _ -> nil
      end
    end
  end

  # -- Helpers ---------------------------------------------------------

  defp mint_secret do
    raw = "emk-" <> (:crypto.strong_rand_bytes(@secret_size) |> Base.url_encode64(padding: false))
    {raw, String.slice(raw, 0, @prefix_size), :crypto.hash(:sha256, raw)}
  end

  defdelegate secure_compare(a, b), to: Emisar.Crypto
end
