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
  alias Ecto.Multi
  alias Emisar.ApiKeys.{ApiKey, Authorizer}
  alias Emisar.{Audit, Auth, Crypto, Repo}
  alias Emisar.Auth.Subject

  # 4 chars for "emk-" + 8 random chars => 12-char prefix.
  @prefix_size 12

  # Keys minted within this window are protected from eviction even
  # when the ring is full — buffer for the "user copied the snippet →
  # LLM makes its first MCP call" gap.
  @quick_eviction_grace_seconds 60

  # -- Reads -----------------------------------------------------------

  @doc """
  Lists MCP / LLM-bridge keys for the Agents page — hides
  auto-generated never-used ones AND hides audit-export tokens
  (`audit:read`). Audit-export tokens live on the audit page; mixing
  them in here confused operators looking for the LLM keys.
  `:created_by` is preloaded.
  """
  def list_api_keys_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_api_keys_permission()
           ) do
      {preloads, opts} = Keyword.pop(opts, :preload, [])

      ApiKey.Query.visible_to_operators()
      |> ApiKey.Query.without_scope("audit:read")
      |> ApiKey.Query.ordered_by_recent()
      |> apply_api_key_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(ApiKey.Query, opts)
    end
  end

  @doc """
  Lists audit-export tokens (`audit:read`) for the audit page. Same
  visibility rules + creator preload as the agents list, but scoped
  to the SIEM-export bucket only so the audit page renders just the
  keys that actually hit `/api/audit`.
  """
  def list_audit_export_keys_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_api_keys_permission()
           ) do
      {preloads, opts} = Keyword.pop(opts, :preload, [])

      ApiKey.Query.visible_to_operators()
      |> ApiKey.Query.by_scope("audit:read")
      |> ApiKey.Query.ordered_by_recent()
      |> apply_api_key_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(ApiKey.Query, opts)
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

  @doc """
  Validation-only changeset for the create-key form. Pure helper — no
  secret minted, no DB touched, no subject — so a LiveView can drive
  `phx-change` validation and render inline field errors. Submitting
  the validated attrs still goes through `create_key/2`.
  """
  def change_key(attrs \\ %{}), do: ApiKey.Changeset.form(attrs)

  def create_key(attrs, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_api_keys_permission()
           ) do
      account_id = account.id
      user_id = Subject.actor_id(subject)
      membership_id = subject.membership_id
      {raw, prefix, hash} = Crypto.mint("emk-", @prefix_size)

      changeset =
        ApiKey.Changeset.create(account_id, user_id, membership_id, prefix, hash, attrs)

      Multi.new()
      |> Multi.insert(:key, changeset)
      |> Multi.insert(:audit, fn %{key: key} ->
        Audit.Events.api_key_created(subject, key)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_api_key_created(&1.key))
      |> case do
        {:ok, %{key: key}} -> {:ok, raw, key}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Rendering concerns are the caller's: pass `preload:` only for the
  # associations the page actually shows. Unknown atoms raise (caller bug).
  defp apply_api_key_preloads(queryable, preloads) do
    Enum.reduce(preloads, queryable, fn
      :created_by, queryable -> ApiKey.Query.with_preloaded_created_by(queryable)
    end)
  end

  # -- PubSub ----------------------------------------------------------

  @doc "Subscribe the caller to the account's API-key list changes (`{:list_changed, :api_key, …}`)."
  def subscribe_account_api_keys(account_id),
    do: Emisar.PubSub.subscribe(account_api_keys_topic(account_id))

  defp account_api_keys_topic(account_id), do: "account:#{account_id}:api_keys"

  defp broadcast_api_key_created(%ApiKey{} = key) do
    Emisar.PubSub.broadcast(
      account_api_keys_topic(key.account_id),
      {:list_changed, :api_key, "api_key.created", key.id}
    )
  end

  defp broadcast_api_key_revoked(%ApiKey{} = key) do
    Emisar.PubSub.broadcast(
      account_api_keys_topic(key.account_id),
      {:list_changed, :api_key, "api_key.revoked", key.id}
    )
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
      user_id = Subject.actor_id(subject)
      membership_id = subject.membership_id
      cap = opts[:ring_cap] || @quick_ring_cap
      grace_s = opts[:eviction_grace_seconds] || @quick_eviction_grace_seconds
      name = opts[:name] || "Quick connect (auto)"
      runner_filter = opts[:runner_filter] || []
      runner_group_filter = opts[:runner_group_filter] || []

      {raw, prefix, hash} = Crypto.mint("emk-", @prefix_size)

      changeset =
        ApiKey.Changeset.mint_quick(account_id, user_id, membership_id, prefix, hash, %{
          name: name,
          runner_filter: runner_filter,
          runner_group_filter: runner_group_filter
        })

      Multi.new()
      |> Multi.insert(:key, changeset)
      |> Multi.run(:evicted, fn _repo, %{key: key} ->
        evict_quick_ring_overflow(account_id, cap, grace_s, key.auto_generated_at)
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{key: key}} -> {:ok, raw, key}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp evict_quick_ring_overflow(account_id, cap, grace_seconds, now) do
    protected_floor = DateTime.add(now, -grace_seconds, :second)

    {evicted, _} =
      ApiKey.Query.evictable_quick_overflow(account_id, cap, protected_floor)
      |> Repo.delete_all()

    {:ok, evicted}
  end

  def revoke_api_key(%ApiKey{} = key, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_api_keys_permission()
           ) do
      by_user_id = Subject.actor_id(subject)

      ApiKey.Query.not_deleted()
      |> ApiKey.Query.by_id(key.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(ApiKey.Query,
        with: &ApiKey.Changeset.revoke(&1, by_user_id),
        audit: &Audit.Events.api_key_revoked(subject, &1),
        after_commit: &broadcast_api_key_revoked/1
      )
    end
  end

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
      hash = Crypto.hash(raw)

      # Deliberately all(): `usable?/1` below is the single liveness gate
      # (it rejects deleted/revoked/expired in one place).
      queryable = ApiKey.Query.all() |> ApiKey.Query.by_key_prefix(prefix)

      with %ApiKey{} = key <- Repo.peek(queryable),
           true <- Crypto.secure_compare(key.key_hash, hash),
           true <- ApiKey.usable?(key) do
        was_auto? = ApiKey.auto_unused?(key)

        multi =
          Multi.new()
          |> Multi.update(:key, ApiKey.Changeset.usage(key))

        multi =
          if was_auto? do
            Multi.insert(multi, :audit, fn %{key: updated} ->
              Audit.Events.api_key_bound(updated)
            end)
          else
            multi
          end

        case Repo.commit_multi(multi) do
          {:ok, %{key: updated}} -> updated
          {:error, _} -> nil
        end
      else
        _ -> nil
      end
    end
  end

  @doc """
  Mint a backing MCP key for an OAuth grant. Scoped to actions:read +
  actions:execute and owned by the consenting member's membership, so
  the existing MCP scope/attribution logic applies unchanged. The raw
  secret is generated then DISCARDED — the OAuth client never sees it;
  it authenticates with OAuth access tokens that resolve to this key.

  Internal: called from `Emisar.OAuth` during the authorize step, where
  the operator's consent is the authorization. Returns `{:ok, key}`.
  """
  def create_backing_key(account_id, user_id, membership_id, name) do
    {_raw, prefix, hash} = Crypto.mint("emk-", @prefix_size)

    ApiKey.Changeset.create(account_id, user_id, membership_id, prefix, hash, %{
      name: name,
      scopes: ["actions:read", "actions:execute"]
    })
    |> Repo.insert()
  end

  @doc """
  Load a usable (non-revoked / non-expired / non-deleted) key by id.

  Internal — the MCP auth path uses this to resolve an OAuth access
  token to its backing key. Returns the key or `nil`.
  """
  def peek_api_key_by_id(id) when is_binary(id) do
    # Deliberately all(): `usable?/1` is the single liveness gate.
    case ApiKey.Query.all() |> ApiKey.Query.by_id(id) |> Repo.peek() do
      %ApiKey{} = key -> if ApiKey.usable?(key), do: key, else: nil
      _ -> nil
    end
  end

  @doc """
  Records the MCP clientInfo a key reported at `initialize` so later runs
  can name the client (e.g. "Claude Code").

  Internal — called from the MCP controller after the auth plug resolved
  the key; `info` must already be sanitized to a small string map. The
  caller treats it as best-effort (a failure must not break the
  handshake).
  """
  def record_client_info(%ApiKey{} = key, info) when is_map(info) do
    key
    |> ApiKey.Changeset.record_client_info(info)
    |> Repo.update()
  end

  def record_client_info(_key, _info), do: {:error, :invalid}

  # -- Authorization ---------------------------------------------------

  @doc "Whether `subject` may manage MCP API keys (admin+)."
  def subject_can_manage_api_keys?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_api_keys_permission())
end
