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
  use Supervisor
  alias Ecto.Multi
  alias Emisar.ApiKeys.{ApiKey, Authorizer, DeviceGrant}
  alias Emisar.{Audit, Auth, Crypto, Repo, RequestContext}
  alias Emisar.Auth.Subject
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    children = [job_module("DeviceGrantCleanup")]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp job_module(name), do: Module.safe_concat([__MODULE__, "Jobs", name])

  # 4 chars for "emk-" + 8 random chars => 12-char prefix.
  @prefix_size 12

  # Keys minted within this window are protected from eviction even
  # when the ring is full — buffer for the "user copied the snippet →
  # LLM makes its first MCP call" gap.
  @quick_eviction_grace_seconds 60

  # A key expiring within this window auto-rotates at the MCP boundary —
  # matches the agents page's amber near-expiry cue, so the UI warning and
  # the bridge's self-rotation fire on the same horizon.
  @rotation_window_days 7

  # -- Reads -----------------------------------------------------------

  @doc """
  Lists MCP / LLM-bridge keys (`kind: :mcp`) for the Agents page — hides
  auto-generated never-used ones AND audit-export tokens. Audit-export
  tokens live on the audit page; mixing them in here confused operators
  looking for the LLM keys. `:created_by` is preloaded.
  """
  def list_api_keys_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_api_keys_permission()
           ) do
      {preloads, opts} = Keyword.pop(opts, :preload, [])

      ApiKey.Query.visible_to_operators()
      |> ApiKey.Query.by_kind(:mcp)
      |> ApiKey.Query.ordered_by_recent()
      |> apply_api_key_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(ApiKey.Query, opts)
    end
  end

  @doc """
  `{:ok, [{user_id, email}]}` — the distinct creators of the account's visible
  agent keys (the same `visible_to_operators` + `kind: :mcp` set the agents
  list shows), for that page's "Owner" filter options. `%Subject{}` needs
  `view_api_keys`.
  """
  def list_key_owner_options(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_api_keys_permission()
           ) do
      options =
        ApiKey.Query.visible_to_operators()
        |> ApiKey.Query.by_kind(:mcp)
        |> ApiKey.Query.owner_options()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, options}
    end
  end

  @doc """
  `{:ok, [{key_id, name}]}` — the account's visible agent keys (revoked ones
  included: run history references them), for the runs page's "Agent" filter
  options. `%Subject{}` needs `view_api_keys`.
  """
  def list_key_options(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_api_keys_permission()
           ) do
      options =
        ApiKey.Query.visible_to_operators()
        |> ApiKey.Query.by_kind(:mcp)
        |> ApiKey.Query.options()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, options}
    end
  end

  @doc """
  Lists audit-export tokens (`kind: :audit_export`) for the audit page.
  Same visibility rules + creator preload as the agents list, but scoped
  to the SIEM-export bucket only so the audit page renders just the keys
  that actually hit `/api/audit`.
  """
  def list_audit_export_keys_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_api_keys_permission()
           ) do
      {preloads, opts} = Keyword.pop(opts, :preload, [])

      ApiKey.Query.visible_to_operators()
      |> ApiKey.Query.by_kind(:audit_export)
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

  @doc """
  Mints a fresh successor to an existing key, inheriting its name and kind but
  with a new secret and a fresh default expiry. The successor carries `replaces_id` back to the
  source: the old key keeps working through the overlap window, then the
  successor's FIRST authenticated use proves the client swapped and retires
  the replaced chain automatically (`api_key.retired_by_rotation` in the
  audit trail). The operator can still revoke the old key by hand sooner.
  `%Subject{}` needs `manage_api_keys`; returns `{:ok, raw_secret, new_key}`.
  """
  def rotate_api_key(%ApiKey{} = key, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_api_keys_permission()
           ) do
      {raw, prefix, hash} = Crypto.mint("emk-", @prefix_size)

      source_queryable =
        ApiKey.Query.not_deleted()
        |> ApiKey.Query.by_id(key.id)
        |> ApiKey.Query.lock_for_update()
        |> Authorizer.for_subject(subject)

      Multi.new()
      |> Multi.run(:source, fn repo, _changes ->
        with {:ok, source} <- repo.fetch(source_queryable, ApiKey.Query),
             true <- is_nil(source.revoked_at) do
          {:ok, source}
        else
          false -> {:error, :revoked}
          {:error, reason} -> {:error, reason}
        end
      end)
      |> Multi.insert(:key, fn %{source: source} ->
        ApiKey.Changeset.create(
          source.account_id,
          source.created_by_id,
          source.created_by_membership_id,
          prefix,
          hash,
          successor_attrs(source),
          replaces_id: source.id,
          credential_lineage_id: source.credential_lineage_id
        )
      end)
      |> Multi.insert(:audit, fn %{key: successor} ->
        Audit.Events.api_key_created(subject, successor)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_api_key_created(&1.key))
      |> case do
        {:ok, %{key: successor}} -> {:ok, raw, successor}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Installs the calling MCP key's client-generated rotation successor.
  Possession is the authorization; returns `{:ok, successor}` for both the
  first install and an idempotent retry of the same prefix/hash.
  """
  def install_auto_rotation_successor(
        prefix,
        hash,
        %Subject{actor: %ApiKey{} = key, account: account} = subject
      ) do
    if valid_rotation_material?(prefix, hash) do
      source_queryable =
        ApiKey.Query.not_deleted()
        |> ApiKey.Query.by_id(key.id)
        |> ApiKey.Query.by_account_id(account.id)
        |> ApiKey.Query.lock_for_update()

      Multi.new()
      |> Multi.run(:source, fn repo, _changes ->
        with {:ok, source} <- repo.fetch(source_queryable, ApiKey.Query),
             true <- auto_rotation_eligible?(source) do
          {:ok, source}
        else
          false -> {:error, :not_eligible}
          {:error, reason} -> {:error, reason}
        end
      end)
      |> Multi.run(:successor, fn repo, %{source: source} ->
        install_or_fetch_successor(repo, source, prefix, hash)
      end)
      |> Multi.run(:mark_rotated, fn repo, %{source: source, successor: result} ->
        mark_auto_rotation(repo, source, result)
      end)
      |> Multi.run(:audit, fn repo, %{source: source, successor: result} ->
        insert_auto_rotation_audit(repo, subject, source, result)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_installed_successor/1)
      |> case do
        {:ok, %{successor: %{key: successor}}} -> {:ok, successor}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_successor}
    end
  end

  def install_auto_rotation_successor(_prefix, _hash, %Subject{}),
    do: {:error, :not_eligible}

  defp auto_rotation_eligible?(%ApiKey{} = key) do
    key.kind == :mcp and ApiKey.usable?(key) and expiring_soon?(key.expires_at)
  end

  # A non-expiring MCP key (currently an OAuth backing key) never rotates;
  # auth already guarantees an expiring key is still usable when this runs.
  defp expiring_soon?(nil), do: false

  defp expiring_soon?(%DateTime{} = expires_at) do
    window_end = DateTime.add(DateTime.utc_now(), @rotation_window_days, :day)
    DateTime.compare(expires_at, window_end) == :lt
  end

  defp install_or_fetch_successor(repo, %ApiKey{rotated_to_id: nil} = source, prefix, hash) do
    changeset =
      ApiKey.Changeset.create(
        source.account_id,
        source.created_by_id,
        source.created_by_membership_id,
        prefix,
        hash,
        successor_attrs(source),
        replaces_id: source.id,
        credential_lineage_id: source.credential_lineage_id
      )

    case repo.insert(changeset) do
      {:ok, successor} -> {:ok, %{key: successor, created?: true}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp install_or_fetch_successor(repo, %ApiKey{} = source, prefix, hash) do
    queryable =
      ApiKey.Query.not_deleted()
      |> ApiKey.Query.by_id(source.rotated_to_id)
      |> ApiKey.Query.by_account_id(source.account_id)

    with {:ok, successor} <- repo.fetch(queryable, ApiKey.Query),
         true <- successor.replaces_id == source.id,
         true <- successor.key_prefix == prefix,
         true <- Crypto.secure_compare(successor.key_hash, hash) do
      {:ok, %{key: successor, created?: false}}
    else
      _ -> {:error, :already_rotated}
    end
  end

  defp mark_auto_rotation(_repo, _source, %{created?: false}), do: {:ok, :already_marked}

  defp mark_auto_rotation(repo, source, %{key: successor, created?: true}) do
    queryable =
      ApiKey.Query.all()
      |> ApiKey.Query.by_id(source.id)
      |> ApiKey.Query.not_rotated()

    case repo.update_all(queryable, set: [rotated_to_id: successor.id]) do
      {1, _} -> {:ok, successor.id}
      {0, _} -> {:error, :already_rotated}
    end
  end

  defp insert_auto_rotation_audit(_repo, _subject, _source, %{created?: false}),
    do: {:ok, :already_audited}

  defp insert_auto_rotation_audit(repo, subject, source, %{key: successor, created?: true}) do
    subject
    |> Audit.Events.api_key_auto_rotated(source, successor)
    |> repo.insert()
  end

  defp broadcast_installed_successor(%{successor: %{key: successor, created?: true}}),
    do: broadcast_api_key_created(successor)

  defp broadcast_installed_successor(_changes), do: :ok

  defp valid_rotation_material?(prefix, hash) do
    is_binary(prefix) and byte_size(prefix) == @prefix_size and
      String.valid?(prefix) and String.match?(prefix, ~r/^emk-[A-Za-z0-9_-]{8}$/) and
      is_binary(hash) and byte_size(hash) == 32
  end

  # The attribute set a successor inherits — shared by operator rotation and
  # auto-rotation so the two paths can't drift. Just identity + kind now; the
  # key carries no authorization scope of its own.
  defp successor_attrs(%ApiKey{} = source) do
    %{name: source.name, description: source.description, kind: source.kind}
  end

  # Rendering concerns are the caller's: pass `preload:` only for the
  # associations the page actually shows. Unknown atoms raise (caller bug).
  defp apply_api_key_preloads(queryable, preloads) do
    Enum.reduce(preloads, queryable, fn
      :created_by, queryable -> ApiKey.Query.with_preloaded_created_by(queryable)
      :replaces, queryable -> ApiKey.Query.with_preloaded_replaces(queryable)
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

  # The key's FIRST call — the agent connected. Fires exactly once per key (the
  # auth boundary gates on `first_use?`), so it's not a per-request storm.
  defp broadcast_api_key_first_used(%ApiKey{} = key) do
    Emisar.PubSub.broadcast(
      account_api_keys_topic(key.account_id),
      {:list_changed, :api_key, "api_key.first_used", key.id}
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

  The key is `kind: :mcp`, identity only — it carries no per-key scope; what it
  may do is account Policy + the minting operator's own runner scope. The
  "Custom key" form is the same mint with an operator-set name/expiry.
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

      {raw, prefix, hash} = Crypto.mint("emk-", @prefix_size)

      changeset =
        ApiKey.Changeset.mint_quick(account_id, user_id, membership_id, prefix, hash, %{
          name: name
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

  @doc """
  Explicitly revokes a key and every account-scoped rotation descendant in one
  transaction. `%Subject{}` needs `manage_api_keys`; returns `{:ok, key}` or a
  tagged authorization/not-found/write error.
  """
  def revoke_api_key(%ApiKey{} = key, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_api_keys_permission()
           ) do
      by_user_id = Subject.actor_id(subject)

      source_queryable =
        ApiKey.Query.not_deleted()
        |> ApiKey.Query.by_id(key.id)
        |> ApiKey.Query.lock_for_update()
        |> Authorizer.for_subject(subject)

      Multi.new()
      |> Multi.run(:revocation, fn repo, _changes ->
        revoke_key_chain(repo, source_queryable, subject, by_user_id)
      end)
      |> Repo.commit_multi(
        after_commit: fn %{revocation: %{revoked: revoked}} ->
          Enum.each(revoked, &broadcast_api_key_revoked/1)
        end
      )
      |> case do
        {:ok, %{revocation: %{key: revoked}}} -> {:ok, revoked}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp revoke_key_chain(repo, source_queryable, subject, by_user_id) do
    with {:ok, source} <- repo.fetch(source_queryable, ApiKey.Query),
         descendants = rotation_descendants(repo, source),
         {:ok, revoked_source} <- revoke_and_audit(repo, source, subject, by_user_id, nil),
         {:ok, revoked_descendants} <-
           revoke_descendants(repo, descendants, source, subject, by_user_id) do
      {:ok, %{key: revoked_source, revoked: [revoked_source | revoked_descendants]}}
    end
  end

  defp rotation_descendants(repo, source) do
    rotation_descendants(repo, source.account_id, [source], MapSet.new([source.id]), [])
  end

  defp rotation_descendants(_repo, _account_id, [], _visited, descendants),
    do: Enum.reverse(descendants)

  defp rotation_descendants(repo, account_id, frontier, visited, descendants) do
    replaced_ids = Enum.map(frontier, & &1.id)
    rotated_to_ids = frontier |> Enum.map(& &1.rotated_to_id) |> Enum.reject(&is_nil/1)

    children =
      ApiKey.Query.all()
      |> ApiKey.Query.by_account_id(account_id)
      |> ApiKey.Query.rotation_children(replaced_ids, rotated_to_ids)
      |> ApiKey.Query.lock_for_update()
      |> repo.all()
      |> Enum.reject(&MapSet.member?(visited, &1.id))

    visited = Enum.reduce(children, visited, &MapSet.put(&2, &1.id))
    rotation_descendants(repo, account_id, children, visited, children ++ descendants)
  end

  defp revoke_descendants(repo, descendants, source, subject, by_user_id) do
    Enum.reduce_while(descendants, {:ok, []}, fn descendant, {:ok, revoked} ->
      if is_nil(descendant.deleted_at) and is_nil(descendant.revoked_at) do
        case revoke_and_audit(repo, descendant, subject, by_user_id, source) do
          {:ok, key} -> {:cont, {:ok, [key | revoked]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, {:ok, revoked}}
      end
    end)
    |> case do
      {:ok, revoked} -> {:ok, Enum.reverse(revoked)}
      error -> error
    end
  end

  defp revoke_and_audit(repo, key, subject, by_user_id, cascade_source) do
    audit_changeset =
      if cascade_source,
        do: Audit.Events.api_key_revoked(subject, key, cascade_source),
        else: Audit.Events.api_key_revoked(subject, key)

    with {:ok, revoked} <- repo.update(ApiKey.Changeset.revoke(key, by_user_id)),
         {:ok, _event} <- repo.insert(audit_changeset) do
      {:ok, revoked}
    end
  end

  @doc """
  Internal — revoke every still-active key minted by `membership_id`.
  Called by `Accounts` when a membership is removed or suspended so a
  deprovisioned user loses the delegated execute access their keys carry:
  account-scoped `emk-` keys (and the OAuth backing keys behind `emo-`
  tokens) keep resolving after the user's membership is gone. Accounts
  revokes browser sessions alongside this bulk key update. Both honor the
  `usable?` gate, so flipping `revoked_at` kills MCP dispatch + OAuth
  refresh at once. Bulk update — the `membership_removed`/`_suspended`
  event is the audit anchor. Returns `{:ok, count}`.
  """
  def revoke_keys_for_membership(membership_id) when is_binary(membership_id) do
    now = DateTime.utc_now()

    {count, _} =
      ApiKey.Query.not_deleted()
      |> ApiKey.Query.by_created_by_membership_id(membership_id)
      |> ApiKey.Query.not_revoked()
      |> Repo.update_all(set: [revoked_at: now, updated_at: now])

    {:ok, count}
  end

  @doc """
  Internal — the API-key auth boundary: resolves a presented bearer
  token to an `%ApiKey{}` so the MCP controller's `:authenticate` plug
  can build a `%Subject{}`, so it runs BEFORE any subject exists. Bumps
  `last_used_at` and — if the key is auto-generated — clears the auto
  flag and audit-logs `api_key.bound`. The FIRST use of a rotation
  successor (`replaces_id` set, `last_used_at` nil) proves the client
  swapped, so it also retires the replaced chain — each still-active
  ancestor is revoked with an `api_key.retired_by_rotation` audit row.
  Returns the updated struct or nil (`peek_*` per AGENTS.md §1.1 —
  nil-or-struct credential lookup).
  """
  def peek_api_key_by_secret(raw) when is_binary(raw) do
    if String.length(raw) < @prefix_size do
      nil
    else
      prefix = String.slice(raw, 0, @prefix_size)
      hash = Crypto.hash(raw)

      # `key_prefix` is unique only among live rows. The row lock makes this
      # usability check serialize with explicit revocation: once revoke returns,
      # no stale pre-revocation lookup can authenticate afterward.
      queryable =
        ApiKey.Query.not_deleted()
        |> ApiKey.Query.by_key_prefix(prefix)
        |> ApiKey.Query.lock_for_update()

      multi =
        Multi.new()
        |> Multi.run(:candidate, fn repo, _changes ->
          authenticate_candidate(repo, queryable, hash)
        end)
        |> Multi.update(:key, fn %{candidate: key} -> ApiKey.Changeset.usage(key) end)
        |> Multi.run(:audit, &insert_bound_audit/2)
        |> Multi.run(:retired, &retire_on_first_use/2)

      after_commit = fn changes ->
        Enum.each(changes.retired, &broadcast_api_key_revoked/1)

        # The first call proves the agent connected — reflow the agents list
        # (its status badge) and the connect flow's "waiting" state live.
        if is_nil(changes.candidate.last_used_at),
          do: broadcast_api_key_first_used(changes.key)

        # after_commit callbacks must return :ok (Repo.execute_changes_after_commit).
        :ok
      end

      case Repo.commit_multi(multi, after_commit: after_commit) do
        {:ok, %{key: updated}} ->
          updated

        {:error, :invalid} ->
          nil

        # A valid key, denied only because a lifecycle write blipped. Fail
        # closed, but log it: a silently-rejected good key is undiagnosable.
        # The prefix correlates without exposing the bearer secret.
        {:error, reason} ->
          Logger.warning(
            "api key prefix #{prefix} rejected on a lifecycle-write failure: #{inspect(reason)}"
          )

          nil
      end
    end
  end

  defp authenticate_candidate(repo, queryable, hash) do
    with %ApiKey{} = key <- repo.peek(queryable),
         true <- Crypto.secure_compare(key.key_hash, hash),
         true <- ApiKey.usable?(key) do
      {:ok, key}
    else
      _ -> {:error, :invalid}
    end
  end

  defp insert_bound_audit(repo, %{candidate: candidate, key: updated}) do
    if ApiKey.auto_unused?(candidate) do
      audit = Audit.Events.api_key_bound(updated)
      repo.insert(audit)
    else
      {:ok, nil}
    end
  end

  defp retire_on_first_use(repo, %{candidate: candidate, key: updated}) do
    if is_nil(candidate.last_used_at) and not is_nil(candidate.replaces_id) do
      retire_replaced_chain(repo, updated)
    else
      {:ok, []}
    end
  end

  # Bounded walk up the `replaces_id` chain from a just-first-used successor,
  # revoking every still-active ancestor. Re-scoped to the successor's account
  # even though a link can only be minted same-account — a corrupted link must
  # never retire a foreign key. The conditional `not_revoked` update is the
  # race guard: two concurrent first requests both sweep, one wins each
  # revocation (and writes its audit row); an already-revoked middle key is
  # walked THROUGH, since a hand-revoked successor can hide a live ancestor.
  # A chain is acyclic by construction (links point at strictly older rows);
  # the depth cap is a backstop, and hitting it just leaves the tail for the
  # operator. Returns `{:ok, [retired keys]}`.
  defp retire_replaced_chain(repo, %ApiKey{} = successor) do
    depth_cap = 10
    retire_replaced_link(repo, successor, successor.replaces_id, [], depth_cap)
  end

  defp retire_replaced_link(_repo, _successor, replaced_id, retired, budget)
       when is_nil(replaced_id) or budget == 0,
       do: {:ok, Enum.reverse(retired)}

  defp retire_replaced_link(repo, successor, replaced_id, retired, budget) do
    queryable =
      ApiKey.Query.not_deleted()
      |> ApiKey.Query.by_id(replaced_id)
      |> ApiKey.Query.by_account_id(successor.account_id)

    case repo.peek(queryable) do
      nil ->
        {:ok, Enum.reverse(retired)}

      %ApiKey{} = replaced ->
        retire_and_continue(repo, successor, replaced, retired, budget)
    end
  end

  defp retire_and_continue(repo, successor, replaced, retired, budget) do
    now = DateTime.utc_now()

    revoke_queryable =
      ApiKey.Query.not_deleted()
      |> ApiKey.Query.by_id(replaced.id)
      |> ApiKey.Query.not_revoked()

    case repo.update_all(revoke_queryable, set: [revoked_at: now, updated_at: now]) do
      {1, _} ->
        case repo.insert(Audit.Events.api_key_retired_by_rotation(replaced, successor)) do
          {:ok, _event} ->
            retired = [%{replaced | revoked_at: now} | retired]
            retire_replaced_link(repo, successor, replaced.replaces_id, retired, budget - 1)

          {:error, reason} ->
            {:error, reason}
        end

      {0, _} ->
        retire_replaced_link(repo, successor, replaced.replaces_id, retired, budget - 1)
    end
  end

  @doc """
  Internal — called from `Emisar.OAuth` during the authorize step (the
  operator's consent is the authorization), to mint a backing MCP key
  for an OAuth grant. Scoped to actions:read + actions:execute and owned
  by the consenting member's membership, so the existing MCP
  scope/attribution logic applies unchanged. The raw secret is generated
  then DISCARDED — the OAuth client never sees it; it authenticates with
  OAuth access tokens that resolve to this key. Returns `{:ok, key}`.

  Minted NON-expiring (`default_expiry: false`): OAuth governs the lifecycle —
  the refresh token's 30-day expiry retires an abandoned connection and revoking
  this key is the operator off-switch. Inheriting the 30-day static-MCP-key
  self-heal would instead break every OAuth connection 30 days after consent
  even while it is actively refreshing.
  """
  def create_backing_key(account_id, user_id, membership_id, name) do
    {_raw, prefix, hash} = Crypto.mint("emk-", @prefix_size)

    ApiKey.Changeset.create(
      account_id,
      user_id,
      membership_id,
      prefix,
      hash,
      %{name: name},
      default_expiry: false
    )
    |> Repo.insert()
  end

  @doc """
  Internal — the API-key auth boundary: the MCP auth path uses this to
  resolve an OAuth access token to its backing key (so it runs BEFORE a
  subject exists). Loads a usable (non-revoked / non-expired /
  non-deleted) key by id. Returns the key or `nil`.
  """
  def peek_api_key_by_id(id) when is_binary(id) do
    # Deliberately all(): `usable?/1` is the single liveness gate.
    queryable = ApiKey.Query.all() |> ApiKey.Query.by_id(id)

    case Repo.peek(queryable) do
      %ApiKey{} = key -> if ApiKey.usable?(key), do: key, else: nil
      _ -> nil
    end
  end

  @doc """
  Internal — called from the MCP controller after the auth plug resolved
  the key (already-authorized caller), to record the MCP clientInfo a key
  reported at `initialize` so later runs can name the client (e.g. "Claude
  Code"). `info` must already be sanitized to a small string map. The
  caller treats it as best-effort (a failure must not break the handshake).
  """
  def record_client_info(%ApiKey{} = key, info) when is_map(info) do
    key
    |> ApiKey.Changeset.record_client_info(info)
    |> Repo.update()
  end

  def record_client_info(_key, _info), do: {:error, :invalid}

  @doc """
  Internal — called by `Approvals.create_request` (already-authorized run
  context) to stamp the effective requester on a key-triggered run's
  approval request: the approval gate resolves an MCP run's accountable
  human from the api-key owner, so it takes no subject. Returns the user
  id that created `api_key_id`, or `nil` when the key (or its creator) is
  gone.
  """
  def fetch_owner_user_id(api_key_id) when is_binary(api_key_id) do
    queryable =
      ApiKey.Query.all()
      |> ApiKey.Query.by_id(api_key_id)
      |> ApiKey.Query.select_created_by_id()

    Repo.one(queryable)
  end

  def fetch_owner_user_id(_api_key_id), do: nil

  @doc """
  Whether the account has NO connected LLM agent yet (no visible live MCP key) —
  drives the "connect an agent" nudge dot in the nav. Audit-export tokens and
  auto-minted keys the client has not used yet do not count. Requires `view`;
  returns false (no nudge) when the subject can't view keys.
  """
  def no_agents?(%Subject{account: %{id: account_id}} = subject) do
    case Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_api_keys_permission()) do
      :ok ->
        queryable =
          ApiKey.Query.visible_to_operators()
          |> ApiKey.Query.by_account_id(account_id)
          |> ApiKey.Query.by_kind(:mcp)
          |> ApiKey.Query.not_revoked()

        not Repo.exists?(queryable)

      _ ->
        false
    end
  end

  def no_agents?(%Subject{}), do: false

  # -- Device grants ---------------------------------------------------

  @device_grant_ttl_s 15 * 60
  @device_grant_retention_s 24 * 3_600

  @doc "Device-grant lifetime in seconds — the API layer reports it as `expires_in`."
  def device_grant_ttl_s, do: @device_grant_ttl_s

  @doc """
  Internal — the unauthenticated device-authorization endpoint (RFC 8628
  shape). Opens a pending grant for the installer's requested clients and
  returns `{:ok, device_code, user_code, grant}` — the raw codes exist only
  in this return; the row keeps digests. Retries once when the minted user
  code collides with another live pending grant.
  """
  def open_device_grant(requested_clients, %RequestContext{} = context) do
    do_open_device_grant(requested_clients, context, _retry? = true)
  end

  defp do_open_device_grant(requested_clients, context, retry?) do
    {device_code, device_code_digest} = Crypto.mcp_device_code()
    {user_code, user_code_digest} = Crypto.mcp_device_user_code()
    expires_at = DateTime.add(DateTime.utc_now(), @device_grant_ttl_s, :second)
    attrs = %{requested_clients: requested_clients, requester_ip: context.ip_address}

    changeset =
      DeviceGrant.Changeset.create(device_code_digest, user_code_digest, attrs, expires_at)

    case Repo.insert(changeset) do
      {:ok, grant} ->
        {:ok, device_code, user_code, grant}

      {:error, %Ecto.Changeset{} = failed} ->
        if retry? and user_code_collision?(failed) do
          do_open_device_grant(requested_clients, context, false)
        else
          {:error, failed}
        end
    end
  end

  defp user_code_collision?(%Ecto.Changeset{errors: errors} = changeset) do
    Repo.Changeset.unique_constraint_error?(changeset) and
      Keyword.has_key?(errors, :user_code_digest)
  end

  @doc """
  The pending grant behind a typed user code — the approval page's read.
  Requires `issue_quick_key`. Deliberately not account-scoped (no
  `for_subject`): a pending grant carries no account until an approver binds
  one at approval — the documented IL-4 exception.
  Returns `{:ok, grant}` or `{:error, :unauthorized | :not_found}`.
  """
  def fetch_pending_device_grant_by_user_code(user_code, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.issue_quick_key_permission()
           ) do
      digest = Crypto.mcp_device_user_code_digest(user_code)

      DeviceGrant.Query.by_user_code_digest(digest)
      |> DeviceGrant.Query.by_status(:pending)
      |> DeviceGrant.Query.not_expired(DateTime.utc_now())
      |> Repo.fetch(DeviceGrant.Query)
    end
  end

  @doc """
  Approves a pending grant into the subject's CURRENT account: binds the
  approver's identity — which is what later authorizes the claim-time mint —
  and flips the grant to `approved` under a row lock, so a concurrent
  approve/deny/sweep loses cleanly as `:not_found`. Requires
  `issue_quick_key`. Returns `{:ok, grant}` or
  `{:error, :unauthorized | :not_found}`.
  """
  def approve_device_grant(user_code, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.issue_quick_key_permission()
           ) do
      account_id = account.id
      user_id = Subject.actor_id(subject)
      membership_id = subject.membership_id
      digest = Crypto.mcp_device_user_code_digest(user_code)

      DeviceGrant.Query.by_user_code_digest(digest)
      |> DeviceGrant.Query.by_status(:pending)
      |> DeviceGrant.Query.not_expired(DateTime.utc_now())
      |> DeviceGrant.Query.lock_for_update()
      |> Repo.fetch_and_update(DeviceGrant.Query,
        with: &DeviceGrant.Changeset.approve(&1, account_id, user_id, membership_id),
        audit: &Audit.Events.device_grant_approved(subject, &1)
      )
    end
  end

  @doc """
  Denies a pending grant — the poll then reports `access_denied` and the
  installer stops. Records the denier for the audit trail. Requires
  `issue_quick_key`. Returns `{:ok, grant}` or
  `{:error, :unauthorized | :not_found}`.
  """
  def deny_device_grant(user_code, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.issue_quick_key_permission()
           ) do
      account_id = account.id
      user_id = Subject.actor_id(subject)
      membership_id = subject.membership_id
      digest = Crypto.mcp_device_user_code_digest(user_code)

      DeviceGrant.Query.by_user_code_digest(digest)
      |> DeviceGrant.Query.by_status(:pending)
      |> DeviceGrant.Query.not_expired(DateTime.utc_now())
      |> DeviceGrant.Query.lock_for_update()
      |> Repo.fetch_and_update(DeviceGrant.Query,
        with: &DeviceGrant.Changeset.deny(&1, account_id, user_id, membership_id),
        audit: &Audit.Events.device_grant_denied(subject, &1)
      )
    end
  end

  @doc """
  Internal — the device-token poll (RFC 8628 semantics). Redeems an approved
  grant EXACTLY once: locks the row, mints one auto-generated `:mcp` key per
  requested client on behalf of the recorded approver (the approval is the
  authorization — this path has no subject by design, like magic-link
  redemption), flips the grant to `claimed`, and returns `{:ok, client_keys}`
  as a `client id => raw secret` map — the only time the secrets exist.
  Every other state maps to its poll error:
  `{:error, :authorization_pending | :access_denied | :expired_token | :invalid_grant}`.
  """
  def claim_device_grant(device_code) when is_binary(device_code) do
    digest = Crypto.mcp_device_code_digest(device_code)

    Multi.new()
    |> Multi.run(:grant, fn repo, _changes ->
      queryable =
        DeviceGrant.Query.by_device_code_digest(digest)
        |> DeviceGrant.Query.lock_for_update()

      judge_claimable(repo.peek(queryable), repo)
    end)
    |> Multi.run(:client_keys, fn repo, %{grant: grant} ->
      mint_grant_keys(repo, grant)
    end)
    |> Multi.run(:claimed, fn repo, %{grant: grant} ->
      repo.update(DeviceGrant.Changeset.claim(grant))
    end)
    |> Multi.run(:evicted, fn _repo, %{grant: grant} ->
      evict_quick_ring_overflow(
        grant.account_id,
        @quick_ring_cap,
        @quick_eviction_grace_seconds,
        DateTime.utc_now()
      )
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{client_keys: client_keys}} -> {:ok, client_keys}
      {:error, reason} -> {:error, reason}
    end
  end

  # The poll-state machine: only an unexpired approved grant whose approver
  # still exists yields keys; every other state is its RFC 8628 poll error.
  defp judge_claimable(nil, _repo), do: {:error, :invalid_grant}
  defp judge_claimable(%DeviceGrant{status: :claimed}, _repo), do: {:error, :invalid_grant}
  defp judge_claimable(%DeviceGrant{status: :denied}, _repo), do: {:error, :access_denied}
  defp judge_claimable(%DeviceGrant{status: :expired}, _repo), do: {:error, :expired_token}

  defp judge_claimable(%DeviceGrant{} = grant, repo) do
    cond do
      DeviceGrant.expired?(grant) -> {:error, :expired_token}
      grant.status == :pending -> {:error, :authorization_pending}
      true -> ensure_approver_still_valid(grant, repo)
    end
  end

  # A removed approver or deleted account kills the grant — the recorded
  # identity IS the claim-time authorization, so it must still exist. The
  # struct preload on an internal, already-authorized path is the sanctioned
  # IL-10 exception (the assocs' `where: [deleted_at: nil]` does the vetting).
  defp ensure_approver_still_valid(%DeviceGrant{} = grant, repo) do
    grant = repo.preload(grant, [:account, :approved_by_membership])

    if is_nil(grant.account) or is_nil(grant.approved_by_membership) do
      {:error, :access_denied}
    else
      {:ok, grant}
    end
  end

  # Deliberate per-row inserts: each key mints its own secret via a
  # `mint_quick` changeset (auto-generated, invisible until first use — the
  # quick-mint semantics), and the whole loop aborts atomically inside the
  # claim transaction on the first failure. N is bounded by the client list.
  defp mint_grant_keys(repo, %DeviceGrant{} = grant) do
    Enum.reduce_while(grant.requested_clients, {:ok, %{}}, fn client, {:ok, acc} ->
      {raw, prefix, hash} = Crypto.mint("emk-", @prefix_size)

      changeset =
        ApiKey.Changeset.mint_quick(
          grant.account_id,
          grant.approved_by_id,
          grant.approved_by_membership_id,
          prefix,
          hash,
          %{name: DeviceGrant.client_label(client)}
        )

      case repo.insert(changeset) do
        {:ok, _key} -> {:cont, {:ok, Map.put(acc, client, raw)}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  @doc """
  Internal — the DeviceGrantCleanup job's sweep. Expires overdue pending
  grants (freeing their user codes for reuse) and hard-deletes rows older
  than a day — grants are minutes-lived operational state, not audit history
  (approval/denial already wrote durable audit events). Returns
  `{expired, deleted}`.
  """
  def cleanup_device_grants(now \\ DateTime.utc_now()) do
    {expired, _} =
      DeviceGrant.Query.by_status(:pending)
      |> DeviceGrant.Query.expired_before(now)
      |> Repo.update_all(set: [status: :expired, updated_at: now])

    retention_cutoff = DateTime.add(now, -@device_grant_retention_s, :second)

    {deleted, _} =
      DeviceGrant.Query.older_than(retention_cutoff)
      |> Repo.delete_all()

    {expired, deleted}
  end

  # -- Authorization ---------------------------------------------------

  @doc "True when the subject may view the LLM agent keys (the console nav + section gate)."
  def subject_can_view_api_keys?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.view_api_keys_permission())

  @doc "Whether the subject can quick-mint an agent key (operators and above) — the connect flow's gate."
  def subject_can_issue_quick_key?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.issue_quick_key_permission())

  @doc "Whether `subject` may manage MCP API keys (admin+)."
  def subject_can_manage_api_keys?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_api_keys_permission())
end
