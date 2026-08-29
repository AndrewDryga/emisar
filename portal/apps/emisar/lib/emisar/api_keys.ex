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
  alias Emisar.{Accounts, Audit, Auth, Billing, Crypto, Repo, RequestContext, Users}
  alias Emisar.ApiKeys.{ApiKey, Authorizer, DeviceGrant}
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
  # Audit-export tokens carry their kind in the prefix, so a pasted credential
  # is identifiable at a glance and support never has to ask which kind it is.
  # Same 8 random lookup characters as an agent key, after a longer literal.
  @export_prefix "emk-export-"
  @export_prefix_size byte_size(@export_prefix) + 8

  # last_used_at is a coarse activity indicator, not an audit record — audit
  # rows carry the exact trail. Rewriting it on every authenticated MCP call
  # (up to the 300/min rate cap) was pure WAL and dead-tuple churn on the
  # hottest request path, so a stamp fresher than this window is left alone.
  # First use (nil) always writes: promotion, retirement, and the connect
  # flow's "agent connected" flip all key off that transition.
  @usage_stamp_interval_seconds 60

  # Keys minted within this window are protected from eviction even
  # when the ring is full — buffer for the "user copied the snippet →
  # LLM makes its first MCP call" gap.
  @quick_eviction_grace_seconds 60

  # A key expiring within this window auto-rotates at the MCP boundary —
  # matches the agents page's amber near-expiry cue, so the UI warning and
  # the bridge's self-rotation fire on the same horizon.
  @rotation_window_days 7

  # Auto-rotation mints a successor with a fresh expiry, so the rotation window
  # alone never forces a human back to the console — a leaked key could renew
  # itself indefinitely. Cap the TOTAL age of a rotation lineage instead: once
  # the origin key is older than this ceiling, auto-rotation is refused and the
  # operator must re-mint (the prompt-to-act a stolen key cannot perform).
  # Overridable through the `Emisar.Config` seam for tests.
  @default_max_lineage_age_seconds 90 * 24 * 60 * 60

  # The activity ladder an operator watches: a call inside 5 minutes is a live
  # agent, one inside a day a quiet one, anything older dormant.
  @active_threshold_seconds 5 * 60
  @idle_threshold_seconds 24 * 60 * 60

  # -- Reads -----------------------------------------------------------

  @doc "The Agents table's `%Repo.Filter{}` list."
  def api_key_filters, do: ApiKey.Query.filters()

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
  `{:ok, [{key_id, last_used_at}]}` for at most 100 visible agent-key ids in
  the subject's account. This is the Agents page's bounded activity poll: it
  selects no key secrets, owners, rotation rows, or pagination count. Requires
  `view_api_keys`.
  """
  def list_key_usage_timestamps(ids, %Subject{} = subject) when is_list(ids) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_api_keys_permission()
           ) do
      ids = ids |> Enum.filter(&Repo.valid_uuid?/1) |> Enum.uniq() |> Enum.take(100)

      usage =
        case ids do
          [] ->
            []

          ids ->
            ApiKey.Query.visible_to_operators()
            |> ApiKey.Query.by_kind(:mcp)
            |> ApiKey.Query.by_ids(ids)
            |> ApiKey.Query.select_usage_timestamps()
            |> Authorizer.for_subject(subject)
            |> Repo.all()
        end

      {:ok, usage}
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

  @doc """
  Internal — label resolver for audit attribution: batch `%{key_id => label}`
  naming the human who minted each key, the way `account_id` knows them
  (directory name → nonblank full name → email). Takes ids and an explicit
  already-authorized `account_id` rather than a `%Subject{}` — the caller is
  Audit's subject-less reference resolver. A key outside the account, or one
  whose minting membership is gone, suspended, or in another account, resolves
  to no label, so the caller falls back to the key's own name.
  """
  def owner_labels_for_ids(ids, account_id) when is_list(ids) and is_binary(account_id) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case ids do
      [] ->
        %{}

      ids ->
        ApiKey.Query.all()
        |> ApiKey.Query.by_account_id(account_id)
        |> ApiKey.Query.select_owner_labels(ids, account_id)
        |> Repo.all()
        |> Map.new()
    end
  end

  # -- Key facts -------------------------------------------------------

  @doc """
  How one key reads at `now` — activity, liveness, expiry, rotation lineage,
  reported client and bridge version — as one fixed map, so a caller renders a
  row without re-deriving lifecycle meaning from raw columns. Pure, no subject:
  the key is already the caller's to see. `:replaces` must be preloaded for a
  pending swap to be visible; without it the rotation reads `:settled`.
  """
  def key_facts(%ApiKey{} = key, %DateTime{} = now) do
    activity = activity(key, now)

    %{
      activity: activity,
      # The word the row LEADS with — `with_bridge_compatibility/2` overrides it
      # when the control plane blocks the client's bridge version.
      status: activity,
      usable?: key_usable?(key, now),
      used?: not is_nil(key.last_used_at),
      revoked?: not is_nil(key.revoked_at),
      rotatable?: is_nil(key.revoked_at) and not oauth_backing?(key),
      oauth_backing?: oauth_backing?(key),
      last_used_at: key.last_used_at,
      expires_at: key.expires_at,
      expiry: expiry(key.expires_at, now),
      rotation: rotation(key, now),
      replaced_key_prefix: replaced_key_prefix(key),
      reported_client: reported_client(key),
      distinct_client: distinct_client(key),
      bridge_version: bridge_version(key)
    }
  end

  @doc """
  Folds an `Emisar.Compat` bridge status into the row `status`: a version-blocked
  client leads with `:unsupported` instead of its liveness word, the way a
  retired pack version leads over "trusted". Operator intent still wins — a
  revoked key stays revoked. The caller passes the status, so version policy
  stays with the compatibility module and its meaning here.
  """
  def with_bridge_compatibility(%{activity: :revoked} = facts, _compatibility), do: facts

  def with_bridge_compatibility(facts, :unsupported), do: %{facts | status: :unsupported}

  def with_bridge_compatibility(facts, _compatibility), do: facts

  @doc """
  Rolls a page's `key_facts/2` into the account's agent posture: the raw row
  count, plus counts that only a still-usable credential can contribute to —
  a revoked or expired key is not an agent anyone can reach. `active_today`
  spans active + idle, i.e. a call inside the last 24 hours.
  """
  def summarize_key_facts(facts) when is_list(facts) do
    usable = Enum.filter(facts, & &1.usable?)
    counts = Enum.frequencies_by(usable, & &1.activity)
    active = Map.get(counts, :active, 0)
    idle = Map.get(counts, :idle, 0)

    %{
      total: length(facts),
      live: length(usable),
      connected: Enum.count(usable, & &1.used?),
      active_today: active + idle,
      last_call_at: last_call_at(usable),
      activity: %{
        active: active,
        idle: idle,
        dormant: Map.get(counts, :dormant, 0),
        never_used: Map.get(counts, :never_used, 0)
      }
    }
  end

  @doc """
  Whether the key can still authenticate at `now`: bound to a membership, not
  revoked, not deleted, and either non-expiring or expiring strictly after
  `now`. The single liveness gate behind MCP auth, OAuth token resolution and
  the agents list's live/dead split.
  """
  def key_usable?(%ApiKey{} = key, %DateTime{} = now) do
    is_binary(key.created_by_membership_id) and is_nil(key.revoked_at) and
      is_nil(key.deleted_at) and not expired?(key.expires_at, now)
  end

  defp activity(%ApiKey{revoked_at: revoked_at}, _now) when not is_nil(revoked_at), do: :revoked
  defp activity(%ApiKey{last_used_at: nil}, _now), do: :never_used

  defp activity(%ApiKey{last_used_at: last_used_at}, now) do
    seconds = DateTime.diff(now, last_used_at, :second)

    cond do
      seconds <= @active_threshold_seconds -> :active
      seconds <= @idle_threshold_seconds -> :idle
      true -> :dormant
    end
  end

  defp expiry(nil, _now), do: :none

  defp expiry(%DateTime{} = expires_at, now) do
    cond do
      expired?(expires_at, now) -> :expired
      expiring_soon?(expires_at, now) -> :expiring_soon
      true -> :current
    end
  end

  # Expiry exactly at `now` is already dead — the same boundary the auth path
  # enforces, so a row can never read live for a key that would be refused.
  defp expired?(nil, _now), do: false

  defp expired?(%DateTime{} = expires_at, now),
    do: DateTime.compare(expires_at, now) != :gt

  defp expiring_soon?(%DateTime{} = expires_at, now) do
    window_end = DateTime.add(now, @rotation_window_days, :day)
    DateTime.compare(expires_at, window_end) == :lt
  end

  # The swap is PENDING while the replaced key is still usable — this key's
  # first authenticated use retires it. Once that lands the lineage is forensic
  # (the audit trail keeps it), so it settles.
  defp rotation(%ApiKey{replaces: %ApiKey{} = replaced}, now) do
    if key_usable?(replaced, now), do: :swap_pending, else: :settled
  end

  defp rotation(%ApiKey{replaces_id: nil}, _now), do: :none
  defp rotation(%ApiKey{}, _now), do: :settled

  # Successors inherit the name, so a replaced key is named by its
  # distinguishing prefix.
  defp replaced_key_prefix(%ApiKey{replaces: %ApiKey{} = replaced}), do: replaced.key_prefix
  defp replaced_key_prefix(%ApiKey{}), do: nil

  # The MCP client a key reported at `initialize` (clientInfo): the
  # human-readable "title", else the machine "name". nil until a client has
  # connected.
  defp reported_client(%ApiKey{last_client_info: %{} = info}) do
    label = info["title"] || info["name"]
    if is_binary(label) and label != "", do: label
  end

  defp reported_client(%ApiKey{}), do: nil

  # The connecting client is only worth showing when it ADDS to the key's name:
  # a quick-mint is named after the client it was minted for ("Claude Code"), so
  # the client that then connects ("claude-code") just echoes the title.
  defp distinct_client(%ApiKey{name: name} = key) do
    case reported_client(key) do
      nil -> nil
      client -> if same_client?(client, name), do: nil, else: client
    end
  end

  # Fold case + separators so "Claude Code" and "claude-code" compare equal.
  defp same_client?(client, name), do: normalized_client(client) == normalized_client(name)

  defp normalized_client(value),
    do: value |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  # The emisar-mcp bridge version this key last connected with, captured from
  # the UA at `initialize`. nil for a remote connector, which reports no bridge.
  defp bridge_version(%ApiKey{last_client_info: %{"bridge_version" => version}})
       when is_binary(version),
       do: version

  defp bridge_version(%ApiKey{}), do: nil

  # An OAuth backing key is a non-expiring MCP key: consent mints it without an
  # expiry (`create_backing_key/4`) because OAuth owns the lifecycle through the
  # refresh token, and revocation is the off-switch. Every operator-minted MCP
  # key carries an expiry, so among `:mcp` keys the absent `expires_at`
  # uniquely identifies an OAuth-backed connection — and one can't be rotated,
  # since a fresh `emk-` secret can't reach the OAuth client.
  defp oauth_backing?(%ApiKey{kind: :mcp, expires_at: nil}), do: true
  defp oauth_backing?(%ApiKey{}), do: false

  defp last_call_at(facts) do
    facts
    |> Enum.map(& &1.last_used_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  # -- Mutations -------------------------------------------------------

  @doc """
  Validation-only changeset for the create-key form, taking the same attrs
  `create_key/2` does — including the browser's string-keyed params and its
  `YYYY-MM-DDTHH:MM` expiry. Pure helper — no secret minted, no DB touched, no
  subject — so a LiveView can drive `phx-change` validation and render inline
  field errors.
  """
  def change_key(attrs \\ %{}), do: ApiKey.Changeset.form(attrs)

  @doc """
  Mints an operator-created key of the attrs' `:kind` (`:mcp` default), from
  either internal attrs or the create form's raw browser params. The permission
  follows the kind: an `:mcp` key needs `issue_quick_key`, an `:audit_export`
  token needs `manage_api_keys` plus the account's paid audit-export
  entitlement. Returns `{:ok, raw_secret, key}` or
  `{:error, %Ecto.Changeset{} | :unauthorized | :audit_export_not_available | :not_found}`.
  """
  def create_key(attrs, %Subject{account: account} = subject) do
    account_id = account.id
    user_id = Subject.actor_id(subject)
    membership_id = subject.membership_id
    input_changeset = change_key(attrs)
    kind = Ecto.Changeset.get_field(input_changeset, :kind)

    with :ok <- Auth.Authorizer.ensure_has_permissions(subject, permissions_for_kind(kind)),
         {:ok, input} <- Ecto.Changeset.apply_action(input_changeset, :insert),
         :ok <- ensure_key_kind_available(input.kind, account) do
      {raw, prefix, hash} = mint_for_kind(input.kind)
      changeset = ApiKey.Changeset.create(account_id, user_id, membership_id, prefix, hash, attrs)

      Multi.new()
      |> put_active_account_lock(account_id)
      |> Multi.run(:kind_available, fn repo, _changes ->
        ensure_key_kind_available(input.kind, account_id, repo)
      end)
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
  `%Subject{}` needs `manage_api_keys`, or — on a key it minted itself — the
  permission that minting that kind of key required. For an `:audit_export`
  source it also needs the account's paid audit-export entitlement (the
  successor is a fresh export credential). Returns `{:ok, raw_secret, new_key}`.
  """
  def rotate_api_key(%ApiKey{} = key, %Subject{} = subject) do
    with :ok <- ensure_can_manage_key(key, subject) do
      source_queryable =
        ApiKey.Query.not_deleted()
        |> ApiKey.Query.by_id(key.id)
        |> ApiKey.Query.lock_for_update()
        |> Authorizer.for_subject(subject)

      Multi.new()
      |> put_active_account_lock(subject.account.id)
      |> Multi.run(:source, fn repo, _changes ->
        with {:ok, source} <- repo.fetch(source_queryable, ApiKey.Query),
             :ok <- ensure_can_manage_key(source, subject),
             :ok <- ensure_rotatable(source) do
          {:ok, source}
        end
      end)
      |> Multi.run(:kind_available, fn repo, %{source: source} ->
        ensure_key_kind_available(source.kind, subject.account.id, repo)
      end)
      |> Multi.run(:credential, fn _repo, %{source: source} ->
        {:ok, mint_for_kind(source.kind)}
      end)
      |> Multi.insert(:key, fn %{credential: {_raw, prefix, hash}, source: source} ->
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
        {:ok, %{credential: {raw, _prefix, _hash}, key: successor}} -> {:ok, raw, successor}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Installs the calling MCP key's client-generated rotation successor.
  Possession is the authorization; returns `{:ok, successor}` for both the
  first install and an idempotent retry of the same prefix/hash. Once the
  rotation lineage's origin is older than the configured ceiling a NEW successor
  is refused with `{:error, :lineage_expired}` (an already-installed successor
  still round-trips), so a leaked key cannot renew itself forever.
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
      |> put_active_account_lock(account.id)
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

  defp put_active_account_lock(multi, account_id) do
    Multi.run(multi, :active_account, fn repo, _changes ->
      Accounts.fetch_and_lock_account(account_id, repo: repo)
    end)
  end

  # A non-expiring MCP key (currently an OAuth backing key) never rotates; auth
  # already guarantees an expiring key is still usable when this runs.
  defp auto_rotation_eligible?(%ApiKey{} = key) do
    now = DateTime.utc_now()

    key.kind == :mcp and key_usable?(key, now) and expiry(key.expires_at, now) == :expiring_soon
  end

  # Gate ONLY the creation of a fresh successor — the idempotent-retry clause
  # below never runs this, so a bridge that already rotated keeps working even
  # if its origin has since crossed the ceiling. A missing origin (only reachable
  # if the lineage's first key were hard-deleted) fails closed.
  defp ensure_lineage_within_max_age(repo, %ApiKey{} = source) do
    origin_queryable =
      ApiKey.Query.not_deleted()
      |> ApiKey.Query.by_account_id(source.account_id)
      |> ApiKey.Query.by_credential_lineage_id(source.credential_lineage_id)
      |> ApiKey.Query.lineage_origin()

    case repo.peek(origin_queryable) do
      %ApiKey{inserted_at: %DateTime{} = origin_at} ->
        if DateTime.diff(DateTime.utc_now(), origin_at, :second) > max_lineage_age_seconds(),
          do: {:error, :lineage_expired},
          else: :ok

      nil ->
        {:error, :lineage_expired}
    end
  end

  defp max_lineage_age_seconds do
    Emisar.Config.get_env(
      :emisar,
      :api_key_max_lineage_age_seconds,
      @default_max_lineage_age_seconds
    )
  end

  defp install_or_fetch_successor(repo, %ApiKey{rotated_to_id: nil} = source, prefix, hash) do
    with :ok <- ensure_lineage_within_max_age(repo, source) do
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

  defp mint_for_kind(:audit_export), do: Crypto.mint(@export_prefix, @export_prefix_size)
  defp mint_for_kind(_kind), do: Crypto.mint("emk-", @prefix_size)

  defp raw_prefix_size(raw) do
    if String.starts_with?(raw, @export_prefix), do: @export_prefix_size, else: @prefix_size
  end

  defp valid_rotation_material?(prefix, hash) do
    is_binary(prefix) and byte_size(prefix) == @prefix_size and
      String.valid?(prefix) and String.match?(prefix, ~r/\Aemk-[A-Za-z0-9_-]{8}\z/) and
      is_binary(hash) and byte_size(hash) == 32
  end

  # A revoked key has nothing live to rotate. An OAuth backing key can't be
  # rotated at all: the fresh emk- secret can't reach the OAuth client (ChatGPT
  # holds tokens bound to the OLD backing-key id), and a successor would be minted
  # with the 30-day default expiry, breaking the "OAuth owns the lifecycle"
  # contract. Revoke is the operator's off-switch for both — and the agents UI
  # already hides Rotate here, so this only rejects a crafted event (IL-15).
  defp ensure_rotatable(%ApiKey{revoked_at: revoked}) when not is_nil(revoked),
    do: {:error, :revoked}

  defp ensure_rotatable(%ApiKey{} = source) do
    if oauth_backing?(source), do: {:error, :oauth_backing}, else: :ok
  end

  # Rotating and revoking a key is `manage_api_keys` — EXCEPT on a key you
  # minted yourself, which asks exactly what minting that kind asked for: an
  # operator allowed to issue an `:mcp` key runs the rest of its life too, while
  # an `:audit_export` token still needs `manage_api_keys` (so a demoted admin
  # cannot rotate an inherited export credential into a fresh secret). A viewer
  # holds neither and is refused on their own key — they could never have minted
  # it. Ownership is the minting membership, the column `create_key/2` binds and
  # every successor inherits, so a rotation chain can never cross owners and the
  # cascade revoke stays within one person's keys. The shared-binding match IS
  # the check (the house self-service shape) — never a role-name branch — and
  # `is_binary` stops two nil ids (a membership-unbound key; a subject with no
  # membership) reading as the same person. The actor must be a HUMAN: an MCP
  # subject carries its key's minting membership, so without this a key could
  # manage itself; the machine rotation path is `install_auto_rotation_successor/3`.
  # Callers re-run it on the LOCKED row inside their transaction, so the caller's
  # struct decides nothing.
  defp ensure_can_manage_key(
         %ApiKey{created_by_membership_id: membership_id} = key,
         %Subject{membership_id: membership_id, actor: %Users.User{}} = subject
       )
       when is_binary(membership_id),
       do: Auth.Authorizer.ensure_has_permissions(subject, permissions_for_kind(key.kind))

  defp ensure_can_manage_key(%ApiKey{}, %Subject{} = subject),
    do: Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_api_keys_permission())

  # An MCP key grants nothing its minter doesn't already hold: it authenticates
  # as `:api_client` and resolves the minter's own membership scope at call
  # time, so authoring its name and expiry is the same act as taking a quick
  # key. An `:audit_export` token is a different capability — the whole
  # account's audit stream rather than this member's runner scope — so it keeps
  # `manage_api_keys` on top. Picking the permission LIST from the value being
  # granted keeps one `ensure_has_permissions/2` at the boundary; a crafted
  # `kind` from an operator's form post is refused here, not in the template.
  defp permissions_for_kind(:audit_export),
    do: [Authorizer.manage_api_keys_permission(), Authorizer.issue_quick_key_permission()]

  defp permissions_for_kind(_kind), do: Authorizer.issue_quick_key_permission()

  # An audit-export token is the paid export surface's credential — minting one
  # (directly or as a rotation successor) requires the account's audit-export
  # entitlement. The web's plan checks are courtesy UX; this gate is
  # authoritative. MCP keys are on every plan.
  defp ensure_key_kind_available(:audit_export, %Accounts.Account{} = account) do
    if Billing.audit_export_available?(account),
      do: :ok,
      else: {:error, :audit_export_not_available}
  end

  defp ensure_key_kind_available(_kind, _account), do: :ok

  defp ensure_key_kind_available(:audit_export, account_id, repo) do
    if Billing.audit_export_available_for_account_id?(account_id,
         repo: repo,
         lock?: true
       ),
       do: {:ok, :available},
       else: {:error, :audit_export_not_available}
  end

  defp ensure_key_kind_available(_kind, _account_id, _repo), do: {:ok, :available}

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

  @doc """
  Internal — `Emisar.OAuth.issue_code/3` announces a consent-minted backing key on
  commit, so an already-open agents list reflows to show the new OAuth connection
  (its own mint is inside the OAuth transaction, not an ApiKeys mutation site).
  """
  def broadcast_backing_key_created(%ApiKey{} = key), do: broadcast_api_key_created(key)

  @doc """
  Internal — `Emisar.OAuth.refresh/1` announces a backing key automatically
  revoked after refresh-token reuse, after the containing transaction commits.
  """
  def broadcast_backing_key_revoked(%ApiKey{} = key), do: broadcast_api_key_revoked(key)

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
  transaction. `%Subject{}` needs `manage_api_keys`, or — on a key it minted
  itself — the permission that minting that kind of key required; returns
  `{:ok, key}` or a tagged authorization/not-found/write error.
  """
  def revoke_api_key(%ApiKey{} = key, %Subject{} = subject) do
    with :ok <- ensure_can_manage_key(key, subject) do
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

  @doc """
  Revoke every still-usable agent key a member owns — the lost-or-stolen-device
  containment move. Requires `manage_api_keys`, or the member acting on their
  own keys. Each key is revoked exactly like a single revoke — its own audit
  event, rotation successors falling with their chain — in one transaction.
  Audit-export tokens are a different credential kind (`:audit_export`) and
  are revoked on the audit page. Returns `{:ok, revoked_count}` (0 when nothing was active) or
  `{:error, :unauthorized}`.
  """
  def revoke_all_api_keys_for_member(membership_id, %Subject{} = subject)
      when is_binary(membership_id) do
    with :ok <- ensure_can_revoke_member_keys(membership_id, subject) do
      by_user_id = Subject.actor_id(subject)

      Multi.new()
      |> Multi.run(:revocation, fn repo, _changes ->
        revoke_member_key_chains(repo, membership_id, subject, by_user_id)
      end)
      |> Repo.commit_multi(
        after_commit: fn %{revocation: %{revoked: revoked}} ->
          Enum.each(revoked, &broadcast_api_key_revoked/1)
        end
      )
      |> case do
        {:ok, %{revocation: %{revoked: revoked}}} -> {:ok, length(revoked)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp revoke_member_key_chains(repo, membership_id, subject, by_user_id) do
    queryable =
      ApiKey.Query.not_deleted()
      |> ApiKey.Query.by_created_by_membership_id(membership_id)
      |> ApiKey.Query.by_kind(:mcp)
      |> ApiKey.Query.not_revoked()
      |> ApiKey.Query.lock_for_update()
      |> Authorizer.for_subject(subject)

    keys = repo.all(queryable)

    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, revoked} ->
      # A key already revoked earlier in this loop — as another key's rotation
      # successor — stays revoked; re-running its chain would double its audit.
      if Enum.any?(revoked, &(&1.id == key.id)) do
        {:cont, {:ok, revoked}}
      else
        source_queryable =
          ApiKey.Query.not_deleted()
          |> ApiKey.Query.by_id(key.id)
          |> ApiKey.Query.lock_for_update()
          |> Authorizer.for_subject(subject)

        case revoke_key_chain(repo, source_queryable, subject, by_user_id) do
          {:ok, %{revoked: chain}} -> {:cont, {:ok, revoked ++ chain}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
    |> case do
      {:ok, revoked} -> {:ok, %{revoked: revoked}}
      error -> error
    end
  end

  # Self-service uses the same permission that minting one's own key does; any
  # other member's keys need account-wide manage.
  defp ensure_can_revoke_member_keys(
         membership_id,
         %Subject{membership_id: membership_id, actor: %Users.User{}} = subject
       )
       when is_binary(membership_id),
       do: Auth.Authorizer.ensure_has_permissions(subject, permissions_for_kind(:mcp))

  defp ensure_can_revoke_member_keys(_membership_id, %Subject{} = subject),
    do: Auth.Authorizer.ensure_has_permissions(subject, Authorizer.manage_api_keys_permission())

  defp revoke_key_chain(repo, source_queryable, subject, by_user_id) do
    with {:ok, source} <- repo.fetch(source_queryable, ApiKey.Query),
         :ok <- ensure_can_manage_key(source, subject),
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
  `key_usable?/2` gate, so flipping `revoked_at` kills MCP dispatch + OAuth
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
  Internal — deny every live approved device grant bound to `membership_id`.
  Membership suspension, removal, or authorization reduction calls this beside
  key revocation so a grant approved before the change cannot mint a replacement
  key afterwards. Returns `{:ok, count}`.
  """
  def revoke_device_grants_for_membership(membership_id) when is_binary(membership_id) do
    now = DateTime.utc_now()

    {count, _} =
      DeviceGrant.Query.by_approved_by_membership_id(membership_id)
      |> DeviceGrant.Query.by_status(:approved)
      |> DeviceGrant.Query.not_expired(now)
      |> Repo.update_all(set: [status: :denied, updated_at: now])

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
    prefix_size = raw_prefix_size(raw)

    if String.length(raw) < prefix_size do
      nil
    else
      prefix = String.slice(raw, 0, prefix_size)
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
        |> Multi.run(:account, fn _repo, %{candidate: key} ->
          case Accounts.fetch_account_by_id(key.account_id) do
            {:ok, account} -> {:ok, account}
            {:error, :not_found} -> {:error, :invalid}
          end
        end)
        |> Multi.run(:key, fn repo, %{candidate: key} -> record_usage(repo, key) end)
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
         true <- key_usable?(key, DateTime.utc_now()) do
      {:ok, key}
    else
      _ -> {:error, :invalid}
    end
  end

  # Skips the write while the stamp is fresh (see @usage_stamp_interval_seconds);
  # the row stays locked either way, so revocation still serializes with use.
  defp record_usage(repo, %ApiKey{last_used_at: %DateTime{} = at} = key) do
    if DateTime.diff(DateTime.utc_now(), at, :second) < @usage_stamp_interval_seconds do
      {:ok, key}
    else
      repo.update(ApiKey.Changeset.usage(key))
    end
  end

  defp record_usage(repo, %ApiKey{last_used_at: nil} = key),
    do: repo.update(ApiKey.Changeset.usage(key))

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
  Internal composition step for OAuth refresh-token reuse containment. Locks
  the exact non-deleted OAuth backing key, revokes it when still live, and
  returns whether this call performed the transition. OAuth owns the surrounding
  transaction, successor-token revocation, and reuse audit event.
  """
  def put_oauth_refresh_reuse_revocation(%Multi{} = multi, api_key_id)
      when is_binary(api_key_id) do
    Multi.run(multi, :oauth_backing_key_revocation, fn repo, _changes ->
      queryable =
        ApiKey.Query.oauth_backing()
        |> ApiKey.Query.not_deleted()
        |> ApiKey.Query.by_id(api_key_id)
        |> ApiKey.Query.lock_for_update()

      with {:ok, key} <- repo.fetch(queryable, ApiKey.Query) do
        if is_nil(key.revoked_at) do
          case repo.update(ApiKey.Changeset.revoke(key, nil)) do
            {:ok, revoked} -> {:ok, %{key: revoked, revoked?: true}}
            {:error, reason} -> {:error, reason}
          end
        else
          {:ok, %{key: key, revoked?: false}}
        end
      end
    end)
  end

  @doc """
  Internal — the API-key auth boundary: the MCP auth path uses this to
  resolve an OAuth access token to its backing key (so it runs BEFORE a
  subject exists). Loads a usable (non-revoked / non-expired /
  non-deleted) key by id. Returns the key or `nil`.
  """
  def peek_api_key_by_id(id) when is_binary(id) do
    # Deliberately all(): `key_usable?/2` is the single liveness gate.
    queryable = ApiKey.Query.all() |> ApiKey.Query.by_id(id)

    case Repo.peek(queryable) do
      %ApiKey{} = key -> if key_usable?(key, DateTime.utc_now()), do: key, else: nil
      _ -> nil
    end
  end

  @doc """
  Internal — the OAuth MCP auth boundary records a backing key's use here. The
  OAuth resolve path (`OAuth.resolve_access_token/2`) holds the backing key's id,
  not its raw secret, so it can't bump usage through `peek_api_key_by_secret/1`;
  without this an OAuth connection's agent row reads "never used" forever and the
  active-agent counts are wrong. Bumps `last_used_at` (an unconditional set —
  last-writer-wins is exactly "last call"), and on the first call broadcasts the
  list reflow so the row flips off "never used" live. Returns the bumped key.
  """
  def record_backing_key_usage(%ApiKey{last_used_at: previous_use} = key) do
    now = DateTime.utc_now()

    {_count, _} =
      ApiKey.Query.not_deleted()
      |> ApiKey.Query.by_id(key.id)
      |> Repo.update_all(set: [last_used_at: now, updated_at: now])

    # Telemetry-only judgment off the resolve-time struct: a rare concurrent
    # double-broadcast just reflows the list twice, so no lock is warranted.
    if is_nil(previous_use), do: broadcast_api_key_first_used(key)

    %{key | last_used_at: now}
  end

  @doc """
  Internal — the OAuth cleanup sweep's candidate lookup. Ids of OAuth backing keys
  (`kind: :mcp`, non-expiring) that never authenticated a call (`last_used_at IS
  NULL`) and were minted before `cutoff`. The caller (`Emisar.OAuth`, which owns
  the tokens) drops any id that still has a token before deleting, so a reachable
  connection is never swept. Returns a list of ids.
  """
  def list_stale_oauth_backing_key_ids(cutoff) do
    ApiKey.Query.all()
    |> ApiKey.Query.oauth_backing()
    |> ApiKey.Query.never_used()
    |> ApiKey.Query.inserted_before(cutoff)
    |> ApiKey.Query.select_ids()
    |> Repo.all()
  end

  @doc """
  Internal — the OAuth cleanup sweep deletes stale backing keys through this.
  Deletes only never-used OAuth backing keys (`kind: :mcp`, non-expiring,
  `last_used_at IS NULL`) among `ids` — self-guarding, so a mis-passed id can
  never remove a real operator key OR a backing key that has authenticated a
  call; the caller supplies ids it has already confirmed hold no token
  (unreachable, since the raw secret was discarded at mint). Returns the count.
  """
  def delete_backing_keys(ids) when is_list(ids) do
    {count, _} =
      ApiKey.Query.all()
      |> ApiKey.Query.by_ids(ids)
      |> ApiKey.Query.oauth_backing()
      |> ApiKey.Query.never_used()
      |> Repo.delete_all()

    count
  end

  @doc "Internal - locked liveness check for a delayed run authorization decision."
  def api_key_usable_in_account?(repo, id, account_id)
      when is_binary(id) and is_binary(account_id) do
    queryable =
      ApiKey.Query.all()
      |> ApiKey.Query.by_id(id)
      |> ApiKey.Query.lock_for_update()

    case repo.one(queryable) do
      %ApiKey{account_id: ^account_id} = key -> key_usable?(key, DateTime.utc_now())
      _ -> false
    end
  end

  def api_key_usable_in_account?(_repo, _id, _account_id), do: false

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
        # "Live" here must mean the same thing it means on the Agents page, which
        # counts `key_usable?/2` keys — expiry included. Without the expiry filter
        # an account holding only expired keys got no nudge while that page showed
        # its own "Connect an agent" panel: two surfaces contradicting each other.
        queryable =
          ApiKey.Query.visible_to_operators()
          |> ApiKey.Query.by_account_id(account_id)
          |> ApiKey.Query.by_kind(:mcp)
          |> ApiKey.Query.not_revoked()
          |> ApiKey.Query.not_expired(DateTime.utc_now())

        not Repo.exists?(queryable)

      _ ->
        false
    end
  end

  def no_agents?(%Subject{}), do: false

  # -- Device grants ---------------------------------------------------

  @device_grant_ttl_s 15 * 60
  @device_grant_retention_s 24 * 3_600

  @doc "Operator-facing label for a device-grant client id."
  def client_label(client), do: DeviceGrant.client_label(client)

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
  redemption), writes an `api_key.created` audit row per key with the
  approver as actor, flips the grant to `claimed`, and returns
  `{:ok, %{client_keys: client_keys, account_id: account_id,
  account_slug: account_slug, account_name: account_name}}`, where `client_keys`
  is a `client id => raw secret` map — the only time the secrets exist — and
  the account fields identify the credential the local CLI stores.
  Every other state maps to its poll error:
  `{:error, :authorization_pending | :access_denied | :expired_token | :invalid_grant}`.
  """
  def claim_device_grant(device_code) when is_binary(device_code) do
    digest = Crypto.mcp_device_code_digest(device_code)

    grant =
      DeviceGrant.Query.by_device_code_digest(digest)
      |> Repo.peek()

    case grant do
      %DeviceGrant{status: :approved} = approved -> claim_approved_device_grant(digest, approved)
      grant -> {:error, judge_device_grant_state(grant)}
    end
  end

  # The unlocked read identifies which account and membership to lock; it grants
  # no authority. The transaction then follows account -> membership -> grant,
  # rechecking every field under those locks before minting.
  defp claim_approved_device_grant(digest, %DeviceGrant{} = snapshot) do
    Multi.new()
    |> Multi.run(:account, fn repo, _changes ->
      case Accounts.fetch_and_lock_account(snapshot.account_id, repo: repo) do
        {:ok, account} -> {:ok, account}
        {:error, :not_found} -> {:error, :access_denied}
      end
    end)
    |> Multi.run(:membership, fn repo, %{account: account} ->
      case Accounts.fetch_and_lock_membership(
             account.id,
             snapshot.approved_by_membership_id,
             repo: repo
           ) do
        {:ok, membership} -> ensure_grant_approver_authorized(membership, snapshot)
        {:error, :not_found} -> {:error, :access_denied}
      end
    end)
    |> Multi.run(:grant, fn repo, %{account: account, membership: membership} ->
      locked =
        DeviceGrant.Query.by_device_code_digest(digest)
        |> DeviceGrant.Query.lock_for_update()
        |> repo.peek()

      ensure_locked_grant_claimable(locked, account, membership)
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
      {:ok, %{account: account, client_keys: client_keys}} ->
        {:ok,
         %{
           account_id: account.id,
           account_slug: account.slug,
           account_name: account.name,
           client_keys: client_keys
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_grant_approver_authorized(
         %Accounts.Membership{} = membership,
         %DeviceGrant{} = grant
       ) do
    permission = Authorizer.issue_quick_key_permission()
    role = Subject.effective_membership_role(membership)

    if membership.id == grant.approved_by_membership_id and
         membership.account_id == grant.account_id and
         membership.user_id == grant.approved_by_id and
         permission in Authorizer.list_permissions_for_role(role) do
      {:ok, membership}
    else
      {:error, :access_denied}
    end
  end

  defp ensure_locked_grant_claimable(
         %DeviceGrant{} = grant,
         account,
         %Accounts.Membership{} = membership
       ) do
    if grant.account_id == account.id and
         grant.approved_by_membership_id == membership.id and
         grant.approved_by_id == membership.user_id do
      case judge_device_grant_state(grant) do
        :approved -> {:ok, grant}
        reason -> {:error, reason}
      end
    else
      {:error, :access_denied}
    end
  end

  defp ensure_locked_grant_claimable(nil, _account, %Accounts.Membership{}),
    do: {:error, :invalid_grant}

  defp judge_device_grant_state(nil), do: :invalid_grant
  defp judge_device_grant_state(%DeviceGrant{status: :claimed}), do: :invalid_grant
  defp judge_device_grant_state(%DeviceGrant{status: :denied}), do: :access_denied
  defp judge_device_grant_state(%DeviceGrant{status: :expired}), do: :expired_token

  defp judge_device_grant_state(%DeviceGrant{} = grant) do
    cond do
      DeviceGrant.expired?(grant) -> :expired_token
      grant.status == :pending -> :authorization_pending
      grant.status == :approved -> :approved
    end
  end

  # Deliberate per-row inserts: each key mints its own secret via a
  # `mint_quick` changeset (auto-generated, invisible until first use — the
  # quick-mint semantics) plus its own `api_key.created` audit row (the grant
  # is swept within a day, so the audit trail must name the minted key), and
  # the whole loop aborts atomically inside the claim transaction on the
  # first failure. N is bounded by the client list.
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

      with {:ok, key} <- repo.insert(changeset),
           audit_changeset = Audit.Events.api_key_created_via_device_grant(grant, key),
           {:ok, _event} <- repo.insert(audit_changeset) do
        {:cont, {:ok, Map.put(acc, client, raw)}}
      else
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  @doc """
  Internal — the DeviceGrantCleanup job's sweep. Expires overdue pending
  grants (freeing their user codes for reuse) and hard-deletes rows older
  than a day — grants are minutes-lived operational state, not audit history
  (approval/denial/claim already wrote durable audit events). Returns
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

  @doc "True when the subject may bulk-revoke this member's agent keys (manage, or their own)."
  def subject_can_revoke_member_keys?(membership_id, %Subject{} = subject)
      when is_binary(membership_id),
      do: ensure_can_revoke_member_keys(membership_id, subject) == :ok

  @doc """
  Whether `subject` may rotate or revoke THIS key — `manage_api_keys`, or the
  key is one they minted and they still hold what minting it required. The row
  grammar reads off this, so a key you own offers the same verbs an admin gets.
  """
  def subject_can_manage_api_key?(%ApiKey{} = key, %Subject{} = subject),
    do: ensure_can_manage_key(key, subject) == :ok
end
