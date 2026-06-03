defmodule Emisar.Runners do
  @moduledoc """
  Runner lifecycle: registration, auth-key management, token mint/verify,
  state advertisement persistence, connection state.

  Connection state lives in `Emisar.Runners.Presence`, not the database:
  presence is the source of truth for "connected right now" and carries
  the runner's ephemeral state (`action_load`, last heartbeat) in its
  metadata. The DB keeps only durable, event-driven facts.

  Reads/writes go through `Runner.Query` + `Runner.Changeset` (and
  similar per-entity modules under `Emisar.Runners.AuthKey`,
  `Token`, `EventCursor`). The public surface takes `%Subject{}` and
  routes through `Authorizer.for_subject/2`; the runner-socket-driven
  state helpers (`apply_state`, `connect_runner`, `mark_disconnected`,
  `record_heartbeat`, `mark_event_acked`, `event_acked?`) are internal
  to the runner connection process and called with the runner
  socket's own subject upstream.
  """

  alias Ecto.Multi
  alias Emisar.{Audit, Auth, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.Runners.{Authorizer, AuthKey, EventCursor, Presence, Runner, Token}

  require Logger

  # 11 chars for "emkey-auth-" + 16 random chars => 27.
  @auth_key_prefix_size 27
  # 7 chars for "rnrtok-" + 5 random.
  @token_prefix_size 12
  @key_secret_size 32

  # Per-account ring cap for auto-generated, unused install keys.
  # Dashboard mounts mint into the ring; when capacity is exceeded the
  # oldest auto-unused entry is evicted (see `mint_install_key/2`).
  @install_ring_cap 42
  @install_eviction_grace_seconds 60

  # -- Runners: reads --------------------------------------------------

  @doc """
  Batch resolver returning `%{runner_id => runner_name}` for the
  supplied ids. Used by list pages that have foreign-key references
  to runners and want labels without N+1 lookups.

  Label batches are intentionally subjectless — the caller has already
  authorized a parent listing (with its own Subject) and is rendering
  labels for ids it already trusts.
  """
  def runner_labels_for_ids(ids) when is_list(ids) do
    case Enum.reject(ids, &is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        Runner.Query.all()
        |> Runner.Query.select_labels(ids, :name)
        |> Repo.all()
        |> Map.new()
    end
  end

  @doc """
  Flat list of all runners for an account. Used by the grouped
  RunnersLive UI which sorts the rows client-side by group; no
  pagination needed because real fleets are small (≪ 100 runners).
  Use `list_runners_page/2` for paginated/filterable surfaces.

  Returns `{:ok, [runner], %Paginator.Metadata{}}` per the
  context-function convention. The `:membership_id` opt restricts the
  result to runners the membership is allowed to see (post-DB filter;
  empty scopes = all).
  """
  def list_runners_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runners_permission()
           ) do
      {membership_id, opts} = Keyword.pop(opts, :membership_id)
      {group, opts} = Keyword.pop(opts, :group)
      {status, opts} = Keyword.pop(opts, :status)

      Runner.Query.not_deleted()
      |> Runner.Query.ordered_by_group_name()
      |> maybe_by_group(group)
      |> maybe_by_connection(subject, status)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Runner.Query, opts)
      |> decorate_result()
      |> apply_scope_filter(membership_id)
    end
  end

  # Per-user runner ACLs (v1 — uniform per-membership scope). When the
  # caller passes `membership_id: id`, restrict the result to runners
  # the membership is allowed to see (empty scopes = all). Defaults to
  # no filter so MCP/system paths keep working unchanged.
  defp apply_scope_filter({:ok, runners, metadata}, nil), do: {:ok, runners, metadata}

  defp apply_scope_filter({:ok, runners, metadata}, membership_id) do
    case Emisar.Accounts.runner_scopes_for_membership(membership_id) do
      [] ->
        {:ok, runners, metadata}

      scopes ->
        {:ok, Enum.filter(runners, &Emisar.Accounts.runner_in_scope?(&1, scopes)), metadata}
    end
  end

  defp apply_scope_filter({:error, _} = err, _), do: err

  defp maybe_by_group(query, group) when is_binary(group), do: Runner.Query.by_group(query, group)
  defp maybe_by_group(query, _), do: query

  # Connection-state filtering needs the live presence id set, which the
  # DB can't see — resolve it here and hand it to the Query as IN/NOT IN
  # id lists (Firezone's pattern). Scoped to the subject's account.
  defp maybe_by_connection(query, _subject, status) when status in [nil, []], do: query

  defp maybe_by_connection(query, %Subject{account: %{id: account_id}}, status) do
    online_ids = connection_metas(account_id) |> Map.keys()
    Runner.Query.by_connection(query, List.wrap(status), online_ids)
  end

  defp maybe_by_connection(query, _subject, _status), do: query

  @doc """
  Group → count tuples for the RunnersLive sidebar. Returns
  `{:ok, [{group, count}]} | {:error, :unauthorized}`. Small bounded
  set (groups, not runners) — no pagination needed.
  """
  def list_group_summaries(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runners_permission()
           ) do
      rows =
        Runner.Query.not_deleted()
        |> Authorizer.for_subject(subject)
        |> Runner.Query.group_summary()
        |> Repo.all()

      {:ok, rows}
    end
  end

  def fetch_runner_by_id(id, %Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runners_permission()
           ),
         true <- Repo.valid_uuid?(id) do
      Runner.Query.not_deleted()
      |> Runner.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runner.Query, opts)
      |> decorate_result()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Internal lookup by id only — used by socket-driven state updates."
  def peek_runner_by_id(id) do
    if Repo.valid_uuid?(id) do
      Runner.Query.not_deleted()
      |> Runner.Query.by_id(id)
      |> Repo.fetch(Runner.Query)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Internal lookup by `external_id` scoped to an account. Used inside
  `register_via_auth_key/2`; not exposed to LiveView/MCP — they don't
  have an external_id at the auth boundary.
  """
  def fetch_runner_by_external_id_for_account(external_id, account_id)
      when is_binary(external_id) do
    Runner.Query.not_deleted()
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.by_external_id(external_id)
    |> Repo.fetch(Runner.Query)
  end

  # Internal: the live runner currently holding `name` in this account, or
  # `{:error, :not_found}`. Names are unique among live runners, so at most
  # one matches. Used by the register path to detect a name collision before
  # a fresh external_id tries to claim a taken name.
  defp fetch_live_runner_by_name(name, account_id) when is_binary(name) do
    Runner.Query.not_deleted()
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.by_name(name)
    |> Repo.fetch(Runner.Query)
  end

  # -- Runners: mutations ----------------------------------------------

  def create_runner(attrs, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runners_permission()
           ) do
      %Emisar.Accounts.Account{id: account.id}
      |> Runner.Changeset.create(attrs)
      |> Repo.insert()
    end
  end

  def update_runner(%Runner{} = runner, attrs, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runners_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runner.account_id) do
      runner |> Runner.Changeset.update(attrs) |> Repo.update()
    end
  end

  def disable_runner(%Runner{} = runner, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runners_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runner.account_id) do
      Multi.new()
      |> Multi.update(:runner, Runner.Changeset.disable(runner))
      |> Multi.insert(:audit, fn %{runner: disabled} ->
        Audit.changeset(disabled.account_id, "runner.disabled",
          actor_kind: Subject.actor_kind(subject),
          actor_id: Subject.actor_id(subject),
          subject_kind: "runner",
          subject_id: disabled.id,
          subject_label: disabled.name
        )
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{runner: disabled}} -> {:ok, disabled}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Re-enables a disabled runner — clears `disabled_at`. A disabled runner
  doesn't occupy a plan slot (`Billing.current_count` excludes it), so
  re-enabling claims one back and is refused with
  `{:error, :over_limit, plan, limit}` when the account is already at its
  runner ceiling. Returns `{:ok, runner}` otherwise.
  """
  def enable_runner(%Runner{} = runner, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runners_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runner.account_id),
         account = Emisar.Accounts.fetch_account_by_id!(runner.account_id),
         :ok <- Emisar.Billing.check_limit(account, :runners) do
      Multi.new()
      |> Multi.update(:runner, Runner.Changeset.enable(runner))
      |> Multi.insert(:audit, fn %{runner: enabled} ->
        Audit.changeset(enabled.account_id, "runner.enabled",
          actor_kind: Subject.actor_kind(subject),
          actor_id: Subject.actor_id(subject),
          subject_kind: "runner",
          subject_id: enabled.id,
          subject_label: enabled.name
        )
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{runner: enabled}} -> {:ok, enabled}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Soft-deletes a runner — sets `deleted_at`. The runner becomes
  invisible from the default scope (`Query.not_deleted/1`) but
  historical references (audit events, run rows) remain intact.
  """
  def delete_runner(%Runner{} = runner, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runners_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runner.account_id) do
      Multi.new()
      |> Multi.update(:runner, Runner.Changeset.delete(runner))
      |> Multi.insert(:audit, fn %{runner: deleted} ->
        Audit.changeset(deleted.account_id, "runner.deleted",
          actor_kind: Subject.actor_kind(subject),
          actor_id: Subject.actor_id(subject),
          subject_kind: "runner",
          subject_id: deleted.id,
          subject_label: deleted.name
        )
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{runner: deleted}} -> {:ok, deleted}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -- Runner socket-driven connection state ---------------------------
  #
  # These run inside the runner WebSocket process — the auth gate is the
  # socket-level token check, and the calling process IS the runner. No
  # Subject thread necessary; row id + account_id come off the runner
  # struct itself. Presence is the source of truth for "connected now";
  # the DB keeps only durable, event-driven facts (last_connected_at,
  # last_disconnected_at, last_disconnect_reason).

  def apply_state(%Runner{} = runner, %{} = payload) do
    runner
    |> Runner.Changeset.apply_state(%{
      hostname: payload["hostname"] || runner.hostname,
      labels: payload["labels"] || runner.labels,
      runner_version: payload["version"] || runner.runner_version,
      packs: payload["packs"] || runner.packs,
      external_id: payload["runner_id"] || runner.external_id
    })
    |> Repo.update()
  end

  @doc """
  Internal — called by the runner socket on connect. Tracks the socket
  process in presence (the live "online" signal) and stamps
  `last_connected_at` for the durable "last seen" history.
  """
  def connect_runner(%Runner{} = runner) do
    meta = %{
      online_at: System.system_time(:second),
      action_load: 0,
      last_heartbeat_at: nil,
      node: node()
    }

    case Presence.track(self(), Presence.topic(runner.account_id), runner.id, meta) do
      {:ok, _ref} ->
        :ok

      {:error, reason} ->
        # Don't fail the connect over a tracker hiccup — the DB still stamps
        # last_connected_at and the heartbeat-timeout watcher closes a
        # genuinely dead socket. Surface it for diagnosis.
        Logger.warning("presence track failed for runner #{runner.id}: #{inspect(reason)}")
    end

    runner
    |> Runner.Changeset.connected()
    |> Repo.update()
  end

  @doc """
  Internal — called by the runner socket each heartbeat. Refreshes the
  runner's ephemeral state in presence metadata; never touches the DB.
  """
  def record_heartbeat(account_id, runner_id, action_load) do
    Presence.update(self(), Presence.topic(account_id), runner_id, fn meta ->
      %{
        meta
        | action_load: action_load || meta.action_load,
          last_heartbeat_at: System.system_time(:second)
      }
    end)
  end

  def mark_disconnected(runner_or_id, reason \\ nil)

  def mark_disconnected(%Runner{} = runner, reason) do
    runner
    |> Runner.Changeset.disconnected(reason)
    |> Repo.update()
  end

  def mark_disconnected(runner_id, reason) when is_binary(runner_id) do
    case peek_runner_by_id(runner_id) do
      {:ok, runner} -> mark_disconnected(runner, reason)
      {:error, :not_found} = err -> err
    end
  end

  # -- Connection state reads (Phoenix.Presence) -----------------------

  @doc "True when the runner currently has a live socket tracked in presence."
  def online?(account_id, runner_id) do
    case Map.get(connection_metas(account_id), runner_id) do
      %{metas: [_ | _]} -> true
      _ -> false
    end
  end

  @doc "Raw presence map for an account: `%{runner_id => %{metas: [meta, ...]}}`."
  def connection_metas(account_id), do: Presence.list(Presence.topic(account_id))

  @doc "Subscribe the caller to this account's runner presence diffs."
  def subscribe_connections(account_id) do
    Phoenix.PubSub.subscribe(Emisar.PubSub.Server, Presence.topic(account_id))
  end

  @doc """
  Derived connection state for a runner struct carrying the virtual
  `online?` field (set by `list_runners_for_account/2` and
  `fetch_runner_by_id/3` from presence). `:disabled` and `:pending`
  win over a stale socket so the operator UI reads true.
  """
  def connection_state(%Runner{disabled_at: %DateTime{}}), do: :disabled
  def connection_state(%Runner{online?: true}), do: :online
  def connection_state(%Runner{last_connected_at: nil}), do: :pending
  def connection_state(%Runner{}), do: :offline

  # Fill the virtual online?/action_load/last_heartbeat_at fields from
  # presence so read callers get connection state without a second
  # lookup. Grouped by account_id so a multi-account listing decorates
  # correctly. Mirrors Firezone's preload_presence.
  defp decorate_result({:ok, runners, metadata}),
    do: {:ok, decorate_connection(runners), metadata}

  defp decorate_result({:ok, runner}), do: {:ok, decorate_connection(runner)}
  defp decorate_result({:error, _} = err), do: err

  defp decorate_connection([]), do: []

  defp decorate_connection(runners) when is_list(runners) do
    metas_by_account =
      runners
      |> Enum.map(& &1.account_id)
      |> Enum.uniq()
      |> Map.new(fn account_id -> {account_id, connection_metas(account_id)} end)

    Enum.map(runners, fn runner ->
      put_connection_meta(runner, get_in(metas_by_account, [runner.account_id, runner.id]))
    end)
  end

  defp decorate_connection(%Runner{} = runner) do
    put_connection_meta(runner, Map.get(connection_metas(runner.account_id), runner.id))
  end

  defp put_connection_meta(runner, %{metas: [meta | _]}) do
    %{
      runner
      | online?: true,
        action_load: meta.action_load,
        last_heartbeat_at: unix_to_datetime(meta.last_heartbeat_at)
    }
  end

  defp put_connection_meta(runner, _absent), do: %{runner | online?: false}

  defp unix_to_datetime(nil), do: nil
  defp unix_to_datetime(unix) when is_integer(unix), do: DateTime.from_unix!(unix)

  # -- Auth keys -------------------------------------------------------

  def list_auth_keys(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_auth_keys_permission()
           ) do
      AuthKey.Query.visible_to_operators()
      |> AuthKey.Query.ordered_by_recent()
      |> Authorizer.for_subject(subject)
      |> Repo.list(AuthKey.Query, Keyword.put_new(opts, :preload, :created_by))
    end
  end

  def create_auth_key(attrs, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_auth_keys_permission()
           ) do
      account_id = account.id
      user_id = Subject.actor_id(subject)
      {raw, prefix, hash} = mint_secret("emkey-auth-", @auth_key_prefix_size)

      Multi.new()
      |> Multi.insert(:key, AuthKey.Changeset.create(account_id, user_id, prefix, hash, attrs))
      |> Multi.insert(:audit, fn %{key: key} ->
        Audit.changeset(account_id, "auth_key.created",
          actor_kind: "user",
          actor_id: user_id,
          subject_kind: "auth_key",
          subject_id: key.id,
          payload: %{prefix: key.key_prefix, reusable: key.reusable, group: key.group}
        )
      end)
      |> Repo.commit_multi(after_commit: &broadcast_auth_key_change(&1, "auth_key.created"))
      |> case do
        {:ok, %{key: key}} -> {:ok, raw, key}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp broadcast_auth_key_change(%{key: key}, event_type) do
    Emisar.PubSub.broadcast_account_list(key.account_id, :auth_key, event_type, key.id)
    :ok
  end

  @doc false
  # Seed/test helper that persists an auth key with a caller-supplied
  # raw secret. Production paths MUST use `create_auth_key/2` so the
  # secret is randomized server-side. A known raw value defeats the
  # randomization that makes auth keys worth anything as credentials.
  def create_auth_key_with_secret(raw, account_id, user_id, attrs \\ %{})
      when is_binary(raw) and byte_size(raw) >= @auth_key_prefix_size do
    prefix = String.slice(raw, 0, @auth_key_prefix_size)
    hash = :crypto.hash(:sha256, raw)

    AuthKey.Changeset.create(account_id, user_id, prefix, hash, attrs)
    |> Repo.insert()
  end

  @doc """
  Mints a fresh, single-use bootstrap auth key for the dashboard's
  install command, marks it auto-generated, and evicts the oldest
  auto-unused key beyond the per-account ring cap of #{@install_ring_cap}.

  Returns `{:ok, raw_secret, key}`. No audit log on mint — auto-gen is
  noise. Once a runner registers with the key, `consume_auth_key/1`
  clears the auto flag and audit logs `auth_key.bound` with `auto: true`.
  """
  def mint_install_key(%Subject{account: account} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.issue_install_key_permission()
           ) do
      account_id = account.id
      user_id = Subject.actor_id(subject)
      cap = opts[:ring_cap] || @install_ring_cap
      grace_s = opts[:eviction_grace_seconds] || @install_eviction_grace_seconds

      {raw, prefix, hash} = mint_secret("emkey-auth-", @auth_key_prefix_size)

      Repo.transaction(fn ->
        # Insert first, then evict — so the account never momentarily has
        # zero auto-unused keys (which would race against concurrent
        # dashboard mounts).
        {:ok, key} =
          AuthKey.Changeset.mint_install(account_id, user_id, prefix, hash, %{})
          |> Repo.insert()

        evict_install_ring_overflow(account_id, cap, grace_s, key.auto_generated_at)
        {raw, key}
      end)
      |> case do
        {:ok, {raw, key}} -> {:ok, raw, key}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp evict_install_ring_overflow(account_id, cap, grace_seconds, now) do
    protected_floor = DateTime.add(now, -grace_seconds, :second)

    AuthKey.Query.evictable_install_overflow(account_id, cap, protected_floor)
    |> Repo.delete_all()
  end

  def revoke_auth_key(%AuthKey{} = key, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_auth_keys_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, key.account_id) do
      by_user_id = Subject.actor_id(subject)

      result =
        Multi.new()
        |> Multi.update(:key, AuthKey.Changeset.revoke(key, by_user_id))
        |> Multi.insert(:audit, fn %{key: revoked} ->
          Audit.changeset(revoked.account_id, "auth_key.revoked",
            actor_kind: "user",
            actor_id: by_user_id,
            subject_kind: "auth_key",
            subject_id: revoked.id,
            payload: %{prefix: revoked.key_prefix}
          )
        end)
        |> Repo.commit_multi(after_commit: &broadcast_auth_key_change(&1, "auth_key.revoked"))

      case result do
        {:ok, %{key: revoked}} ->
          {:ok, revoked}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Peeks at the presented raw secret, resolving it to an `%AuthKey{}`.
  Returns nil when there's no match or the key is unusable (revoked/
  deleted/expired/single-use exhausted). Constant-time hash comparison.
  `peek_*` per CLAUDE.md §1.1 — nil-or-struct credential lookup.

  Internal — only called from the runner-register controller before
  any Subject exists. The presented raw secret IS the auth.
  """
  def peek_auth_key_by_secret(raw) when is_binary(raw) do
    if String.length(raw) < @auth_key_prefix_size do
      nil
    else
      hash = :crypto.hash(:sha256, raw)
      peek_by_prefix(raw, hash, @auth_key_prefix_size)
    end
  end

  defp peek_by_prefix(raw, hash, size) do
    if String.length(raw) < size do
      nil
    else
      prefix = String.slice(raw, 0, size)

      with %AuthKey{} = key <-
             AuthKey.Query.all() |> AuthKey.Query.by_key_prefix(prefix) |> Repo.peek(),
           true <- secure_compare(key.key_hash, hash),
           true <- AuthKey.usable?(key) do
        key
      else
        _ -> nil
      end
    end
  end

  # -- Per-runner tokens -----------------------------------------------

  @doc """
  Mints a long-lived per-runner token, persists the hash, returns
  `{raw_token, token_record}`. Internal — only called from the
  registration flow.
  """
  def mint_runner_token(%Runner{} = runner, issued_via_key_id \\ nil) do
    {raw, prefix, hash} = mint_secret("rnrtok-", @token_prefix_size)

    {:ok, token} =
      Token.Changeset.create(runner.id, issued_via_key_id, prefix, hash)
      |> Repo.insert()

    {raw, token}
  end

  @doc """
  Verifies a presented runner token. Returns `{:ok, token, runner}` or
  `{:error, :token_invalid}`. Internal — called from the runner socket
  upgrade controller before any Subject exists.
  """
  def verify_runner_token(raw) when is_binary(raw) do
    if String.length(raw) < @token_prefix_size do
      {:error, :token_invalid}
    else
      prefix = String.slice(raw, 0, @token_prefix_size)
      hash = :crypto.hash(:sha256, raw)

      with %Token{} = token <-
             Token.Query.all() |> Token.Query.by_prefix(prefix) |> Repo.peek(),
           true <- secure_compare(token.token_hash, hash),
           true <- Token.usable?(token),
           %Runner{disabled_at: nil, deleted_at: nil} = runner <-
             Runner.Query.all() |> Runner.Query.by_id(token.runner_id) |> Repo.peek() do
        {:ok, _} = token |> Token.Changeset.usage() |> Repo.update()
        {:ok, token, runner}
      else
        _ -> {:error, :token_invalid}
      end
    end
  end

  # -- Registration (auth_key -> runner + token exchange) --------------

  @doc """
  Called when a runner presents a valid auth key on first connect.
  Creates the runner record (or returns the existing one for a reusable
  key registration) and mints a fresh per-runner token. Also enforces
  the account's runner-count plan limit.

  Returns `{:ok, runner, token, raw_token}` on success or
  `{:error, reason}` / `{:error, :over_limit, plan, limit}`.

  Internal — called from the runner-register controller with only the
  raw secret in hand; the secret IS the auth, no Subject yet exists.
  """
  def register_via_auth_key(raw, attrs) when is_binary(raw) do
    case peek_auth_key_by_secret(raw) do
      nil -> {:error, :auth_key_invalid}
      %AuthKey{} = key -> register_via_auth_key(key, attrs)
    end
  end

  def register_via_auth_key(%AuthKey{} = key, attrs) do
    account = Emisar.Accounts.fetch_account_by_id!(key.account_id)
    was_auto? = AuthKey.auto_unused?(key)

    case Emisar.Billing.check_limit(account, :runners) do
      :ok ->
        Repo.transaction(fn ->
          # Atomically claim a use of this auth key. The conditional
          # UPDATE only succeeds if the key is still in a usable state
          # AT the moment of the update — defeating the race where two
          # concurrent registrations both see uses_count = 0.
          case consume_auth_key(key) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          # Surface the auto→permanent promotion. The mint itself was
          # deliberately silent (would flood the log with noise), so
          # binding is where this key first becomes visible.
          if was_auto? do
            Audit.log(key.account_id, "auth_key.bound",
              actor_kind: "system",
              subject_kind: "auth_key",
              subject_id: key.id,
              payload: %{prefix: key.key_prefix, auto: true}
            )
          end

          # Identity is (account, external_id) — the stable id the runner
          # persists and sends. Reuse the existing row on reconnect;
          # otherwise insert. Names are display-only and may repeat across
          # runners, so external_id is the only uniqueness here. A blank id
          # (older runner that doesn't send one) gets a server-minted UUID
          # — never treated as a shared empty-string key.
          external_id =
            case attrs[:external_id] do
              id when is_binary(id) and id != "" -> id
              _ -> Ecto.UUID.generate()
            end

          {runner, fresh?} =
            case fetch_runner_by_external_id_for_account(external_id, key.account_id) do
              {:ok, %Runner{} = existing} -> {existing, false}
              {:error, :not_found} -> insert_runner!(key, attrs, external_id)
            end

          if fresh? do
            Audit.log(runner.account_id, "runner.registered",
              actor_kind: "runner",
              actor_id: runner.id,
              actor_label: runner.name,
              subject_kind: "runner",
              subject_id: runner.id,
              subject_label: runner.name,
              payload: %{
                external_id: runner.external_id,
                group: runner.group,
                hostname: runner.hostname,
                auth_key_id: key.id
              }
            )
          end

          {raw_token, token} = mint_runner_token(runner, key.id)
          {runner, token, raw_token}
        end)
        |> case do
          {:ok, {runner, token, raw_token}} -> {:ok, runner, token, raw_token}
          {:error, {:runner_name_taken, name}} -> {:error, :runner_name_taken, name}
          {:error, reason} -> {:error, reason}
        end

      {:error, :over_limit, plan, limit} ->
        {:error, :over_limit, plan, limit}
    end
  end

  # Insert a brand-new runner. `on_conflict: :nothing` on
  # (account, external_id) makes a concurrent register with the same id
  # a no-op instead of a constraint error that would poison the
  # transaction (Postgres 25P02); we then re-fetch the canonical row and
  # report whether *this* call inserted it. Returns `{runner, fresh?}`.
  #
  # The unique index is partial (`WHERE deleted_at IS NULL`) so a
  # soft-deleted runner frees its external_id — the conflict target has to
  # carry the same predicate or Postgres won't match the partial index.
  # An :unsafe_fragment is the only way to express that in Ecto; the
  # columns/predicate are literals here, so there's nothing to interpolate.
  defp insert_runner!(key, attrs, external_id) do
    name = derive_name(attrs)

    # Names are unique among live runners. We're here because no live runner
    # has this external_id, so if another live runner already holds this name
    # it's a real conflict: bail with a clean error the controller turns into
    # a 409 ("delete/rename the other runner") instead of a constraint crash.
    # The partial unique index is the race backstop in the insert below.
    case fetch_live_runner_by_name(name, key.account_id) do
      {:ok, %Runner{}} ->
        Repo.rollback({:runner_name_taken, name})

      {:error, :not_found} ->
        changeset =
          Runner.Changeset.register(%{
            account_id: key.account_id,
            name: name,
            external_id: external_id,
            group: attrs[:group] || key.group || "default",
            hostname: attrs[:hostname],
            labels: attrs[:labels] || %{},
            runner_version: attrs[:version] || attrs[:runner_version],
            bootstrap_auth_key_id: key.id
          })

        case Repo.insert(changeset,
               on_conflict: :nothing,
               conflict_target:
                 {:unsafe_fragment, "(account_id, external_id) WHERE deleted_at IS NULL"}
             ) do
          {:ok, inserted} ->
            {:ok, runner} = fetch_runner_by_external_id_for_account(external_id, key.account_id)
            {runner, runner.id == inserted.id}

          {:error, changeset} ->
            if name_taken_changeset?(changeset),
              do: Repo.rollback({:runner_name_taken, name}),
              else: Repo.rollback(changeset)
        end
    end
  end

  # A changeset error from the (account_id, name) partial unique index — vs a
  # plain validation error — so a race that slips past the pre-check still
  # surfaces as `:runner_name_taken` rather than a generic failure.
  defp name_taken_changeset?(%Ecto.Changeset{errors: errors}) do
    case errors[:name] do
      {_msg, opts} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end
  end

  # Atomically charge one use against `key`. The WHERE clause
  # re-evaluates every `usable?` condition at SQL level so we can't
  # TOCTOU between SELECT and UPDATE.
  defp consume_auth_key(%AuthKey{} = key) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query =
      AuthKey.Query.consumable_by_id(key.id, now)
      |> AuthKey.Query.consume_one(now)

    case Repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> {:error, :auth_key_invalid}
    end
  end

  defp derive_name(attrs) do
    attrs[:hostname] || attrs[:name] ||
      "runner-#{Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)}"
  end

  # -- Event cursor (audit-upload outbox) ------------------------------
  #
  # Internal — called only by the runner socket process. The runner
  # is the authority on what its own cursor is.

  def mark_event_acked(runner_id, event_id) do
    EventCursor.Changeset.upsert(runner_id, event_id)
    |> Repo.insert(on_conflict: :nothing)
  end

  def event_acked?(runner_id, event_id) do
    EventCursor.Query.all()
    |> EventCursor.Query.by_runner_id(runner_id)
    |> EventCursor.Query.by_event_id(event_id)
    |> Repo.exists?()
  end

  # -- Helpers ---------------------------------------------------------

  defp mint_secret(prefix, expected_prefix_size) do
    rand = :crypto.strong_rand_bytes(@key_secret_size) |> Base.url_encode64(padding: false)
    raw = prefix <> rand
    {raw, String.slice(raw, 0, expected_prefix_size), :crypto.hash(:sha256, raw)}
  end

  defdelegate secure_compare(a, b), to: Emisar.Crypto
end
