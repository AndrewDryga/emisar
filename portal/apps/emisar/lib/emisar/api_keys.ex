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
  require Logger

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

  # `opts` is internal (rotation threads `replaces_id:` through) — the web
  # always calls this as `create_key(attrs, subject)`.
  def create_key(attrs, subject, opts \\ [])

  def create_key(attrs, %Subject{account: account} = subject, opts) do
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
        ApiKey.Changeset.create(account_id, user_id, membership_id, prefix, hash, attrs, opts)

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
    # Re-fetch scoped to the subject so a caller can't rotate a key outside its
    # account; `create_key/3` then re-gates on `manage_api_keys` and mints.
    with {:ok, source} <- fetch_api_key_by_id(key.id, subject) do
      create_key(successor_attrs(source), subject, replaces_id: source.id)
    end
  end

  @doc """
  Possession-based self-succession for the MCP bridge (response-carried
  rotation): when the subject's OWN `:mcp` key expires within
  #{@rotation_window_days} days, mints a successor exactly
  once and returns `{:ok, raw_secret, successor}`. The
  `%Subject{actor: %ApiKey{}}` match IS the authorization — the credential
  rotates itself; no `manage_api_keys` involved — so any other subject, or an
  ineligible key, gets `{:error, :not_eligible}`, and losing the mark-race to
  a concurrent session gets `{:error, :already_rotated}`. The source key
  keeps working through the overlap window, then the successor's first use
  retires it (`replaces_id` + the first-use sweep in `peek_api_key_by_secret`).
  """
  def auto_rotate_expiring(%Subject{actor: %ApiKey{} = key} = subject) do
    if auto_rotation_eligible?(key) do
      mint_successor(key, subject)
    else
      {:error, :not_eligible}
    end
  end

  def auto_rotate_expiring(%Subject{}), do: {:error, :not_eligible}

  defp auto_rotation_eligible?(%ApiKey{} = key) do
    key.kind == :mcp and is_nil(key.revoked_at) and is_nil(key.deleted_at) and
      is_nil(key.rotated_to_id) and expiring_soon?(key.expires_at)
  end

  # Quick-connect keys carry no expiry and never rotate; auth already
  # guarantees the key isn't past its expiry when this runs.
  defp expiring_soon?(nil), do: false

  defp expiring_soon?(%DateTime{} = expires_at) do
    window_end = DateTime.add(DateTime.utc_now(), @rotation_window_days, :day)
    DateTime.compare(expires_at, window_end) == :lt
  end

  defp mint_successor(%ApiKey{} = source, subject) do
    {raw, prefix, hash} = Crypto.mint("emk-", @prefix_size)

    changeset =
      ApiKey.Changeset.create(
        source.account_id,
        source.created_by_id,
        source.created_by_membership_id,
        prefix,
        hash,
        successor_attrs(source),
        replaces_id: source.id
      )

    Multi.new()
    |> Multi.insert(:successor, changeset)
    |> Multi.run(:mark_rotated, fn repo, %{successor: successor} ->
      # The conditional update is the at-most-once guard: a concurrent
      # initialize that already marked the source loses here, rolling the
      # freshly-inserted successor back out.
      queryable =
        ApiKey.Query.all() |> ApiKey.Query.by_id(source.id) |> ApiKey.Query.not_rotated()

      case repo.update_all(queryable, set: [rotated_to_id: successor.id]) do
        {1, _} -> {:ok, successor.id}
        {0, _} -> {:error, :already_rotated}
      end
    end)
    |> Multi.insert(:audit, fn %{successor: successor} ->
      Audit.Events.api_key_auto_rotated(subject, source, successor)
    end)
    |> Repo.commit_multi(after_commit: &broadcast_api_key_created(&1.successor))
    |> case do
      {:ok, %{successor: successor}} -> {:ok, raw, successor}
      {:error, reason} -> {:error, reason}
    end
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
  Internal — revoke every still-active key minted by `membership_id`.
  Called by `Accounts` when a membership is removed or suspended so a
  deprovisioned user loses the delegated execute access their keys carry:
  account-scoped `emk-` keys (and the OAuth backing keys behind `emo-`
  tokens) keep resolving after the user's membership is gone, unlike
  sessions, which self-heal at membership resolution. Both honor the
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

      # Deliberately all(): `usable?/1` below is the single liveness gate
      # (it rejects deleted/revoked/expired in one place).
      queryable = ApiKey.Query.all() |> ApiKey.Query.by_key_prefix(prefix)

      with %ApiKey{} = key <- Repo.peek(queryable),
           true <- Crypto.secure_compare(key.key_hash, hash),
           true <- ApiKey.usable?(key) do
        was_auto? = ApiKey.auto_unused?(key)
        # nil→set happens exactly once, so first_use? — and the rotation-retire
        # + the "agent connected" broadcast it gates — cost nothing on every
        # later request with this key.
        first_use? = is_nil(key.last_used_at)
        completes_rotation? = first_use? and not is_nil(key.replaces_id)

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

        multi =
          if completes_rotation? do
            Multi.run(multi, :retired, fn repo, %{key: updated} ->
              retire_replaced_chain(repo, updated)
            end)
          else
            multi
          end

        after_commit = fn changes ->
          Enum.each(Map.get(changes, :retired, []), &broadcast_api_key_revoked/1)
          # The first call proves the agent connected — reflow the agents list
          # (its status badge) and the connect flow's "waiting" state live.
          if first_use?, do: broadcast_api_key_first_used(changes.key)
          # after_commit callbacks must return :ok (Repo.execute_changes_after_commit).
          :ok
        end

        case Repo.commit_multi(multi, after_commit: after_commit) do
          {:ok, %{key: updated}} ->
            updated

          # A VALID key, denied only because the usage-tracking write blipped.
          # Fail closed, but log it — a silently-rejected good key is otherwise
          # undiagnosable. The prefix correlates without exposing the secret.
          {:error, reason} ->
            Logger.warning(
              "api key #{key.id} (prefix #{prefix}) rejected on a usage-write failure: #{inspect(reason)}"
            )

            nil
        end
      else
        _ -> nil
      end
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
  Whether the account has NO connected LLM agent yet (no non-revoked API key) —
  drives the "connect an agent" nudge dot in the nav. Requires `view`; returns
  false (no nudge) when the subject can't view keys.
  """
  def no_agents?(%Subject{account: %{id: account_id}} = subject) do
    case Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_api_keys_permission()) do
      :ok ->
        queryable =
          ApiKey.Query.not_deleted()
          |> ApiKey.Query.by_account_id(account_id)
          |> ApiKey.Query.not_revoked()

        not Repo.exists?(queryable)

      _ ->
        false
    end
  end

  def no_agents?(%Subject{}), do: false

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
