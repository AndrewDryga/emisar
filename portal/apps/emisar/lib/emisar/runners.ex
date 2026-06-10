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
  `Token`). The public surface takes `%Subject{}` and
  routes through `Authorizer.for_subject/2`; the runner-socket-driven
  state helpers (`apply_state`, `connect_runner`, `mark_disconnected`,
  `record_heartbeat`) are internal
  to the runner connection process and called with the runner
  socket's own subject upstream.
  """
  alias Ecto.Multi
  alias Emisar.{Accounts, Audit, Auth, Crypto, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.Runners.{Authorizer, AuthKey, Presence, Runner, Token, UserRunnerScope}
  require Logger

  # 11 chars for "emkey-auth-" + 16 random chars => 27.
  @auth_key_prefix_size 27
  # 7 chars for "rnrtok-" + 5 random.
  @token_prefix_size 12

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
      |> scope_to_membership(membership_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Runner.Query, opts)
      |> decorate_result()
    end
  end

  @doc """
  Every non-deleted runner for the subject's account — the COMPLETE
  set, deliberately un-paginated, presence-decorated.

  The MCP path: `tools/list`, dispatch resolution, and runner
  inventory must see every runner (no `status`/`group`/membership
  filter), not a page. The UI uses the paginated
  `list_runners_for_account/2`. Returns `{:ok, runners}`.
  """
  def list_all_runners_for_account(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runners_permission()
           ) do
      runners =
        Runner.Query.not_deleted()
        |> Runner.Query.ordered_by_group_name()
        |> Authorizer.for_subject(subject)
        |> Repo.all()
        |> decorate_connection()

      {:ok, runners}
    end
  end

  # Per-membership runner ACLs: restrict to the runners a membership may see
  # (empty scopes = all). Filters in the query — BEFORE pagination — so the
  # page contents and the metadata counts are correct (the old post-fetch
  # in-memory filter left short pages with inflated totals). nil membership =
  # no filter, so MCP / system paths see everything.
  defp scope_to_membership(query, nil), do: query

  defp scope_to_membership(query, membership_id) do
    case runner_scopes_for_membership(membership_id) do
      [] ->
        query

      scopes ->
        runner_ids = for %{scope_type: :runner, scope_value: v} <- scopes, do: v
        groups = for %{scope_type: :group, scope_value: v} <- scopes, do: v
        Runner.Query.by_scope_values(query, runner_ids, groups)
    end
  end

  defp maybe_by_group(query, group) when is_binary(group), do: Runner.Query.by_group(query, group)
  defp maybe_by_group(query, _), do: query

  # Connection-state filtering needs the live presence id set, which the
  # DB can't see — resolve it here and hand it to the Query as IN/NOT IN
  # id lists. Scoped to the subject's account.
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

  @doc """
  Internal — the Runs dispatch gate: true when the runner exists in
  `account_id` and is neither soft-deleted nor disabled (a disabled
  runner must refuse new dispatches).
  """
  def runner_active_in_account?(runner_id, account_id) do
    Runner.Query.not_deleted()
    |> Runner.Query.not_disabled()
    |> Runner.Query.by_id(runner_id)
    |> Runner.Query.by_account_id(account_id)
    |> Repo.exists?()
  end

  @doc """
  Internal — the runbook engine's group-target resolution: active (not
  deleted, not disabled) runners in `group`, ordered by name so the
  engine's work list is stable across continuation recomputes.
  """
  def list_active_runners_in_group(account_id, group) when is_binary(group) do
    Runner.Query.not_deleted()
    |> Runner.Query.not_disabled()
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.by_group(group)
    |> Runner.Query.ordered_by_group_name()
    |> Repo.all()
  end

  @doc """
  Internal — Billing seat counting: active (not deleted, not disabled)
  runners in the account. Disabled runners don't occupy a plan slot.
  """
  def count_billable_runners(account_id) do
    Runner.Query.not_deleted()
    |> Runner.Query.not_disabled()
    |> Runner.Query.by_account_id(account_id)
    |> Repo.aggregate(:count, :id)
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
      changeset =
        %Emisar.Accounts.Account{id: account.id}
        |> Runner.Changeset.create(attrs)

      case Repo.insert(changeset) do
        {:ok, runner} ->
          {:ok, runner}

        {:error, %Ecto.Changeset{} = errored} ->
          # Retry with the PRISTINE changeset — the errored one is invalid
          # and would fail the Multi insert on its own carried errors.
          with true <- name_taken_changeset?(errored),
               {:ok, runner} <- replace_inactive_name_holder(changeset, account.id, subject) do
            {:ok, runner}
          else
            _ -> {:error, errored}
          end
      end
    end
  end

  # The taken name may belong to a dead runner (reinstalled host, renamed
  # fleet) — replacing it beats forcing the operator to hunt down and delete
  # the corpse first. Only an OFFLINE holder is displaced (soft-deleted, so
  # its history survives); a connected one keeps the conflict error.
  defp replace_inactive_name_holder(%Ecto.Changeset{} = changeset, account_id, subject) do
    name = Ecto.Changeset.get_field(changeset, :name)

    with {:ok, %Runner{} = existing} <- fetch_live_runner_by_name(name, account_id),
         false <- online?(account_id, existing.id) do
      Multi.new()
      |> Multi.update(:replaced, Runner.Changeset.delete(existing))
      |> Multi.insert(:runner, changeset)
      |> Multi.insert(:audit, fn %{runner: runner} ->
        Audit.Events.runner_replaced(subject, existing, runner)
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{runner: runner}} -> {:ok, runner}
        {:error, reason} -> {:error, reason}
      end
    else
      # The holder is actively connected — or vanished between the failed
      # insert and this read. Let the caller surface the original conflict.
      _ -> :conflict
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
        Audit.Events.runner_disabled(subject, disabled)
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
         runner = Repo.preload(runner, :account),
         :ok <- Emisar.Billing.check_limit(runner.account, :runners) do
      Multi.new()
      |> Multi.update(:runner, Runner.Changeset.enable(runner))
      |> Multi.insert(:audit, fn %{runner: enabled} ->
        Audit.Events.runner_enabled(subject, enabled)
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
        Audit.Events.runner_deleted(subject, deleted)
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

  @doc "Internal — persists a runner_state advertisement from the runner socket."
  def apply_state(%Runner{} = runner, %{} = payload) do
    runner
    |> Runner.Changeset.apply_state(%{
      hostname: payload["hostname"] || runner.hostname,
      labels: payload["labels"] || runner.labels,
      runner_version: payload["version"] || runner.runner_version,
      packs: payload["packs"] || runner.packs,
      external_id: payload["runner_id"] || runner.external_id,
      # A config `runner.group` rename reaches the cloud here, on reconnect —
      # so update it. Keep the existing group when the payload's is missing or
      # blank (never wipe a runner's group to "").
      group: nonblank(payload["group"]) || runner.group
    })
    |> Repo.update()
  end

  defp nonblank(s) when is_binary(s) and s != "", do: s
  defp nonblank(_), do: nil

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

  # Connection-lifecycle audit rows. The runner socket calls these (audit
  # is a domain concern — the web layer never assembles audit rows); they
  # run in the socket process, so the request metadata it stashed in the
  # process dictionary rides along. Fire-and-forget Audit.log/3 — there is
  # no Multi to join (presence/PubSub aren't transactional).

  @doc "Internal — runner socket: audit the WebSocket connect."
  def audit_runner_connected(%Runner{} = runner, token_id) do
    Audit.log(runner.account_id, "runner.connected",
      actor_kind: "runner",
      actor_id: runner.id,
      actor_label: runner.name,
      subject_kind: "runner",
      subject_id: runner.id,
      subject_label: runner.name,
      payload: %{token_id: token_id}
    )
  end

  @doc "Internal — runner socket: audit the WebSocket close."
  def audit_runner_disconnected(account_id, runner_id, reason) do
    Audit.log(account_id, "runner.disconnected",
      actor_kind: "runner",
      actor_id: runner_id,
      subject_kind: "runner",
      subject_id: runner_id,
      payload: %{reason: reason}
    )
  end

  @doc "Internal — runner socket: audit an error envelope reported by the runner."
  def audit_runner_error(account_id, runner_id, %{} = payload) do
    Audit.log(account_id, "runner.error",
      actor_kind: "runner",
      actor_id: runner_id,
      subject_kind: "runner",
      subject_id: runner_id,
      payload: payload
    )
  end

  @doc "Internal — stamps disconnect history from the runner socket on close."
  def mark_disconnected(runner_or_id, reason \\ nil)

  def mark_disconnected(%Runner{} = runner, reason) do
    runner
    |> Runner.Changeset.disconnected(reason)
    |> Repo.update()
  end

  def mark_disconnected(runner_id, reason) when is_binary(runner_id) do
    case peek_runner_by_id(runner_id) do
      {:ok, runner} -> mark_disconnected(runner, reason)
      {:error, :not_found} -> {:error, :not_found}
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
  # correctly.
  defp decorate_result({:ok, runners, metadata}),
    do: {:ok, decorate_connection(runners), metadata}

  defp decorate_result({:ok, runner}), do: {:ok, decorate_connection(runner)}
  defp decorate_result({:error, reason}), do: {:error, reason}

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

  # -- Per-membership runner scopes (ACLs) -----------------------------
  #
  # Empty scope list = all runners (default). Any rows = union of
  # (group, runner) tuples — a runner is in-scope when its id OR its
  # group matches at least one row.

  @doc """
  All scope rows for a membership, ordered for stable rendering.

  Internal cross-context resolver — called from `Runners` /
  `Runs.dispatch_run` which have already authorized via Subject, and from
  the team-page LV which has the operator's own membership in scope.
  Tests use it to inspect post-mutation state. Does not take a Subject
  because the row scoping is by `membership_id` (an opaque identifier
  the caller has already proven access to).
  """
  def runner_scopes_for_membership(membership_id) when is_binary(membership_id) do
    UserRunnerScope.Query.by_membership_id(membership_id)
    |> UserRunnerScope.Query.ordered_by_type_and_value()
    |> Repo.all()
  end

  @doc """
  Replaces the scope set for a membership atomically. Pass a list of
  `{scope_type, scope_value}` tuples (or `[]` to clear → all-runners).
  Wrapped in a transaction so a partial failure can't leave a
  half-applied scope set.
  """
  def replace_runner_scopes(
        %Accounts.Membership{id: membership_id} = membership,
        new_scopes,
        %Subject{} = subject
      )
      when is_list(new_scopes) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Accounts.Authorizer.manage_team_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, membership.account_id, :unauthorized) do
      # Validate each scope through the changeset (rejects a bad scope_type,
      # an empty value, etc.), then write the whole set in one INSERT rather
      # than a Multi step per row — it's a simple join table.
      changesets =
        Enum.map(new_scopes, fn {type, value} ->
          UserRunnerScope.Changeset.create(membership_id, type, value)
        end)

      case Enum.find(changesets, &(not &1.valid?)) do
        %Ecto.Changeset{} = invalid ->
          {:error, invalid}

        nil ->
          now = DateTime.utc_now()

          rows =
            Enum.map(changesets, fn changeset ->
              changeset.changes
              |> Map.put(:id, Repo.generate_id())
              |> Map.put(:inserted_at, now)
            end)

          Multi.new()
          |> Multi.delete_all(:cleared, UserRunnerScope.Query.by_membership_id(membership_id))
          |> Multi.insert_all(:scopes, UserRunnerScope, rows)
          |> Multi.insert(:audit, fn _ ->
            Audit.Events.membership_runner_scopes_changed(subject, membership, new_scopes)
          end)
          |> Repo.commit_multi()
          |> case do
            {:ok, _changes} -> {:ok, :ok}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  @doc """
  Batch resolver returning `%{membership_id => [%UserRunnerScope{}]}`
  so a list view can render scope chips without N+1 queries.
  """
  def runner_scopes_for_membership_ids(ids) when is_list(ids) do
    case Enum.reject(ids, &is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        UserRunnerScope.Query.by_membership_ids(ids)
        |> UserRunnerScope.Query.ordered_by_type_and_value()
        |> Repo.all()
        |> Enum.group_by(& &1.membership_id)
    end
  end

  @doc """
  True when the runner is visible/dispatchable for the membership.
  Empty scope = all runners. Otherwise the runner's id OR its group
  must appear in at least one row.

  A membership with no scopes always passes.
  Pass `nil` membership for unauthenticated paths — returns true
  there too; callers must do their own auth check.
  """
  def runner_in_scope?(_runner, nil), do: true

  def runner_in_scope?(runner, %Accounts.Membership{} = membership),
    do: runner_in_scope?(runner, runner_scopes_for_membership(membership.id))

  def runner_in_scope?(_runner, []), do: true

  def runner_in_scope?(%{id: id, group: group}, scopes) when is_list(scopes) do
    Enum.any?(scopes, fn
      %UserRunnerScope{scope_type: :runner, scope_value: ^id} -> true
      %UserRunnerScope{scope_type: :group, scope_value: ^group} -> true
      _ -> false
    end)
  end

  def runner_in_scope?(_runner, _scopes), do: false

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

  @doc """
  Changeset for the auth-key create form (operator-facing fields, no secret
  minted). Drives `phx-change` validation + inline field errors in the
  LiveView; the real key is minted by `create_auth_key/2`.
  """
  def change_auth_key(attrs \\ %{}), do: AuthKey.Changeset.form(attrs)

  def create_auth_key(attrs, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_auth_keys_permission()
           ) do
      account_id = account.id
      user_id = Subject.actor_id(subject)
      {raw, prefix, hash} = Crypto.mint("emkey-auth-", @auth_key_prefix_size)

      Multi.new()
      |> Multi.insert(:key, AuthKey.Changeset.create(account_id, user_id, prefix, hash, attrs))
      |> Multi.insert(:audit, fn %{key: key} ->
        Audit.Events.auth_key_created(subject, key)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_auth_key_change(&1, "auth_key.created"))
      |> case do
        {:ok, %{key: key}} -> {:ok, raw, key}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Subscribe the caller to the account's auth-key list changes (`{:list_changed, :auth_key, …}`)."
  def subscribe_account_auth_keys(account_id),
    do: Emisar.PubSub.subscribe(account_auth_keys_topic(account_id))

  defp account_auth_keys_topic(account_id), do: "account:#{account_id}:auth_keys"

  defp broadcast_auth_key_change(%{key: key}, event_type) do
    Emisar.PubSub.broadcast(
      account_auth_keys_topic(key.account_id),
      {:list_changed, :auth_key, event_type, key.id}
    )

    :ok
  end

  @doc """
  Subscribe the caller to a runner's cloud→runner transport topic. Used
  by the runner socket process; messages arrive as `{:cloud_to_runner, msg}`.
  """
  def subscribe_runner_transport(%Runner{} = runner),
    do: Emisar.PubSub.subscribe(runner_topic(runner.account_id, runner.id))

  @doc """
  Internal — Runs dispatch/cancel: push an outbound envelope to the
  runner's socket process. The topic carries the account id, so a caller
  can only address runners inside the account it already proved.
  """
  def deliver_to_runner(account_id, runner_id, msg),
    do: Emisar.PubSub.broadcast(runner_topic(account_id, runner_id), {:cloud_to_runner, msg})

  defp runner_topic(account_id, runner_id), do: "account:#{account_id}:runner:#{runner_id}"

  @doc false
  # Seed/test helper that persists an auth key with a caller-supplied
  # raw secret. Production paths MUST use `create_auth_key/2` so the
  # secret is randomized server-side. A known raw value defeats the
  # randomization that makes auth keys worth anything as credentials.
  def create_auth_key_with_secret(raw, account_id, user_id, attrs \\ %{})
      when is_binary(raw) and byte_size(raw) >= @auth_key_prefix_size do
    prefix = String.slice(raw, 0, @auth_key_prefix_size)
    hash = Crypto.hash(raw)

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

      {raw, prefix, hash} = Crypto.mint("emkey-auth-", @auth_key_prefix_size)

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
          Audit.Events.auth_key_revoked(subject, revoked)
        end)
        |> Repo.commit_multi(after_commit: &broadcast_auth_key_change(&1, "auth_key.revoked"))

      case result do
        {:ok, %{key: revoked}} ->
          {:ok, revoked}

        {:error, reason} ->
          {:error, reason}
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
      hash = Crypto.hash(raw)
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
           true <- Crypto.secure_compare(key.key_hash, hash),
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
    {raw, prefix, hash} = Crypto.mint("rnrtok-", @token_prefix_size)

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
      hash = Crypto.hash(raw)

      with %Token{} = token <-
             Token.Query.all() |> Token.Query.by_prefix(prefix) |> Repo.peek(),
           true <- Crypto.secure_compare(token.token_hash, hash),
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

  # -- Authorization ---------------------------------------------------

  @doc "Whether `subject` may manage runners (admin+)."
  def subject_can_manage_runners?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_runners_permission())

  @doc "Whether `subject` may manage runner auth keys (admin+)."
  def subject_can_manage_auth_keys?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_auth_keys_permission())

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
    key = Repo.preload(key, :account)
    was_auto? = AuthKey.auto_unused?(key)

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

      # The plan's runner-count limit is enforced only when adding a NEW
      # seat, on the fresh-insert branch and before the row exists (so the
      # count excludes it). A reconnecting runner — e.g. one that lost its
      # token on a redeploy and re-registers via its auth key — is already
      # counted, so checking the limit for it would lock an operator out of
      # their own fleet at the plan ceiling.
      {runner, fresh?} =
        case fetch_runner_by_external_id_for_account(external_id, key.account_id) do
          {:ok, %Runner{} = existing} ->
            {existing, false}

          {:error, :not_found} ->
            case Emisar.Billing.check_limit(key.account, :runners) do
              :ok -> insert_runner!(key, attrs, external_id)
              {:error, :over_limit, plan, limit} -> Repo.rollback({:over_limit, plan, limit})
            end
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
      {:error, {:over_limit, plan, limit}} -> {:error, :over_limit, plan, limit}
      {:error, {:runner_name_taken, name}} -> {:error, :runner_name_taken, name}
      {:error, reason} -> {:error, reason}
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
    # has this external_id, so another live runner holding this name is a
    # conflict — but only an ACTIVE one. An offline holder (reinstalled host,
    # renamed machine) is displaced so a dead runner can't squat the address;
    # a connected holder rolls back to the clean error the controller turns
    # into a 409. The partial unique index is the race backstop below.
    case fetch_live_runner_by_name(name, key.account_id) do
      {:ok, %Runner{} = existing} -> displace_inactive_name_holder!(existing, key, name)
      {:error, :not_found} -> :ok
    end

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

  # Runs inside register_via_auth_key's transaction. A connected holder rolls
  # the registration back; an offline one is soft-deleted (history preserved)
  # with an audit row so the fleet timeline shows where the name went.
  defp displace_inactive_name_holder!(%Runner{} = existing, %AuthKey{} = key, name) do
    if online?(key.account_id, existing.id) do
      Repo.rollback({:runner_name_taken, name})
    else
      {:ok, _} = existing |> Runner.Changeset.delete() |> Repo.update()

      {:ok, _} =
        Audit.log(key.account_id, "runner.replaced",
          actor_kind: "system",
          subject_kind: "runner",
          subject_id: existing.id,
          subject_label: name,
          payload: %{replaced_runner_id: existing.id, auth_key_id: key.id}
        )

      :ok
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
    now = DateTime.utc_now()

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
end
