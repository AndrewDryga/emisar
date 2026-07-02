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
  alias Emisar.RequestContext
  alias Emisar.Runners.{AuthKey, Authorizer, Presence, Runner, Token, UserRunnerScope}
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
  Internal — label batcher: returns `%{runner_id => runner_name}` for the
  supplied ids. Composed by sibling contexts / audit / list pages that
  already authorized a parent listing (with its own Subject) and render
  labels for ids they already trust; no Subject by design.
  """
  def runner_labels_for_ids(ids) when is_list(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case ids do
      [] ->
        %{}

      ids ->
        # Deliberately all(), not not_deleted(): runs and audit rows keep
        # foreign keys to soft-deleted runners, and their labels must
        # still render in history views.
        Runner.Query.all()
        |> Runner.Query.select_labels(ids, :name)
        |> Repo.all()
        |> Map.new()
    end
  end

  @doc """
  Paginated, filterable runner listing for the RunnersLive UI —
  `:group` / `:status` / `:membership_id` opts narrow the set (the
  membership filter applies in the query, before pagination; empty
  scopes = all). Returns `{:ok, [runner], %Paginator.Metadata{}}`,
  presence-decorated. MCP paths that must see the complete fleet use
  `list_all_runners_for_account/1` instead.
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
        runner_ids = for %{scope_type: :runner, scope_value: value} <- scopes, do: value
        groups = for %{scope_type: :group, scope_value: value} <- scopes, do: value
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
        |> Runner.Query.group_summary()
        |> Authorizer.for_subject(subject)
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
  Fetch a single non-deleted runner by its account-unique name. Requires
  `view_runners`; account-scoped. `{:ok, runner} | {:error, :not_found |
  :unauthorized}`. Used to resolve a runner the agent named (MCP `recent_runs`).
  """
  def fetch_runner_by_name(name, %Subject{} = subject, opts \\ []) when is_binary(name) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runners_permission()
           ) do
      Runner.Query.not_deleted()
      |> Runner.Query.by_name(name)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runner.Query, opts)
      |> decorate_result()
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
  Internal — true when any of `runner_ids` is a runner in `account_id` that
  registered with `auth_key_id` as its bootstrap key. The install wizard checks
  this on a presence join so it only advances when the runner minted from THIS
  page's key connects — not any runner that happens to join the account's
  presence (a reconnect, another host coming up).
  """
  def any_runner_bootstrapped_by_key?(runner_ids, auth_key_id, account_id)
      when is_list(runner_ids) and is_binary(auth_key_id) and is_binary(account_id) do
    Runner.Query.not_deleted()
    |> Runner.Query.by_ids(runner_ids)
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.by_bootstrap_auth_key_id(auth_key_id)
    |> Repo.exists?()
  end

  @doc """
  Internal — the Runs dispatch gate: true when the runner advertises that it
  enforces client signatures, so the portal must refuse its own
  (operator/runbook) unsigned dispatch to it. Only a signed MCP call gets through.
  """
  def runner_enforces_signatures?(runner_id, account_id) do
    Runner.Query.not_deleted()
    |> Runner.Query.by_id(runner_id)
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.enforcing()
    |> Repo.exists?()
  end

  @doc """
  Internal — the runbook engine's group-target resolution: active (not
  deleted, not disabled) runners in `groups`, ordered by name so the
  engine's work list is stable across continuation recomputes.
  """
  def list_active_runners_in_groups(_account_id, []), do: []

  def list_active_runners_in_groups(account_id, groups) when is_list(groups) do
    Runner.Query.not_deleted()
    |> Runner.Query.not_disabled()
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.by_groups(Enum.uniq(groups))
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

  @doc """
  Internal — telemetry sampler. FLEET-WIDE (no subject, every account) runner
  connection tally from the DURABLE connection record
  (`last_connected_at`/`last_disconnected_at`/`disabled_at`), NOT live Presence —
  Presence is per-account (no fleet view) and an ungraceful socket drop only
  reaches these columns on the next `mark_disconnected`/reconnect. Good enough
  for an ops trend gauge; the per-account UI stays Presence-accurate. Drives the
  `emisar.runners.connection.*` gauges, fleet-wide by design (no `account_id` —
  series cardinality + tenant enumeration). Returns the four-state tally.
  """
  @spec connection_counts() :: %{
          connected: non_neg_integer(),
          disconnected: non_neg_integer(),
          never_connected: non_neg_integer(),
          disabled: non_neg_integer()
        }
  def connection_counts do
    active = Runner.Query.not_deleted() |> Runner.Query.not_disabled()

    %{
      connected: active |> Runner.Query.connected() |> Repo.aggregate(:count, :id),
      disconnected: active |> Runner.Query.disconnected() |> Repo.aggregate(:count, :id),
      never_connected: active |> Runner.Query.never_connected() |> Repo.aggregate(:count, :id),
      disabled:
        Runner.Query.not_deleted() |> Runner.Query.disabled() |> Repo.aggregate(:count, :id)
    }
  end

  @doc """
  Internal nil-or-struct lookup by id (`peek` per §1.1) — socket-driven
  state updates and sweep workers, where a vanished runner is a
  meaningful state to branch on rather than an error.
  """
  def peek_runner_by_id(id) do
    if Repo.valid_uuid?(id) do
      Runner.Query.not_deleted()
      |> Runner.Query.by_id(id)
      |> Repo.peek()
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

  # -- Runners: mutations ----------------------------------------------

  def create_runner(attrs, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runners_permission()
           ) do
      changeset =
        %Accounts.Account{id: account.id}
        |> Runner.Changeset.create(attrs)

      # A name conflict is a conflict — the unique-index error renders
      # inline on the form; the operator renames or deletes the holder.
      Repo.insert(changeset)
    end
  end

  def disable_runner(%Runner{} = runner, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runners_permission()
           ) do
      Runner.Query.not_deleted()
      |> Runner.Query.by_id(runner.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Runner.Query,
        with: &Runner.Changeset.disable/1,
        audit: &Audit.Events.runner_disabled(subject, &1),
        after_commit: &broadcast_runner_revoked/1
      )
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
         :ok <- Subject.ensure_in_account(subject, runner.account_id) do
      Multi.new()
      # Lock the account so a concurrent enable/register can't both pass the
      # plan-limit count and claim the last slot (TOCTOU).
      |> Multi.run(:lock_account, fn repo, _ ->
        Accounts.fetch_and_lock_account(runner.account_id, repo: repo)
      end)
      # ensure_in_account proved runner.account_id == subject.account.id, so the
      # subject's own account feeds the count — no preload.
      |> Multi.run(:limit, fn _repo, _ ->
        case Emisar.Billing.check_limit(subject.account, :runners) do
          :ok -> {:ok, :ok}
          {:error, :over_limit, plan, limit} -> {:error, {:over_limit, plan, limit}}
        end
      end)
      |> Multi.run(:runner, fn _repo, _ ->
        Runner.Query.not_deleted()
        |> Runner.Query.by_id(runner.id)
        |> Authorizer.for_subject(subject)
        |> Repo.fetch_and_update(Runner.Query,
          with: &Runner.Changeset.enable/1,
          audit: &Audit.Events.runner_enabled(subject, &1)
        )
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{runner: enabled}} -> {:ok, enabled}
        {:error, {:over_limit, plan, limit}} -> {:error, :over_limit, plan, limit}
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
           ) do
      Runner.Query.not_deleted()
      |> Runner.Query.by_id(runner.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Runner.Query,
        with: &Runner.Changeset.delete/1,
        audit: &Audit.Events.runner_deleted(subject, &1),
        after_commit: &broadcast_runner_revoked/1
      )
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
      # `group` is RUNNER-DECLARED: a config `runner.group` rename reaches the
      # cloud here on reconnect, so update it (keep the existing group when the
      # payload's is missing/blank — never wipe to ""). Deliberately trusted:
      # group selects which policy override governs dispatches to THIS runner
      # (Policies.resolve_policy), so a compromised host could declare a looser
      # group — but it already owns the box the runner executes on, so it gains
      # nothing it couldn't do locally. The host is the trust anchor. Pin to the
      # auth key if you need it operator-authoritative. See docs/security-model.md.
      group: nonblank(payload["group"]) || runner.group,
      # Runner-declared too, but trusting it is unconditionally safe: it only
      # makes the runner STRICTER (refuse unsigned dispatch), never looser. A
      # missing/false value clears it, so flipping enforcement off in config
      # propagates on the next reconnect.
      enforce_signatures: payload["enforce_signatures"] == true,
      # The freshness window the runner advertises when enforcing; nil clears it.
      max_attestation_age_seconds: payload["max_attestation_age_seconds"]
    })
    |> Repo.update()
  end

  defp nonblank(value) when is_binary(value) and value != "", do: value
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
  # run in the socket process; the connect `%RequestContext{}` is threaded
  # in so the runner's lifecycle events carry its IP/UA. Fire-and-forget
  # Audit.record/1 — there is no Multi to join (presence/PubSub aren't
  # transactional).

  @doc "Internal — runner socket: audit the WebSocket connect."
  def audit_runner_connected(%Runner{} = runner, token_id, %RequestContext{} = context),
    do: Audit.record(Audit.Events.runner_connected(runner, token_id, context))

  @doc "Internal — runner socket: audit the WebSocket close."
  def audit_runner_disconnected(account_id, runner_id, reason, %RequestContext{} = context),
    do: Audit.record(Audit.Events.runner_disconnected(account_id, runner_id, reason, context))

  @doc "Internal — runner socket: audit an error envelope reported by the runner."
  def audit_runner_error(account_id, runner_id, %{} = payload, %RequestContext{} = context),
    do: Audit.record(Audit.Events.runner_error(account_id, runner_id, payload, context))

  @doc "Internal — stamps disconnect history from the runner socket on close."
  def mark_disconnected(runner_or_id, reason \\ nil)

  def mark_disconnected(%Runner{} = runner, reason) do
    runner
    |> Runner.Changeset.disconnected(reason)
    |> Repo.update()
  end

  def mark_disconnected(runner_id, reason) when is_binary(runner_id) do
    case peek_runner_by_id(runner_id) do
      %Runner{} = runner -> mark_disconnected(runner, reason)
      nil -> {:error, :not_found}
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

  @doc """
  Whether the account's whole active fleet is offline — there's at least one
  billable (active, non-disabled) runner and every one of them is currently
  disconnected. Drives the "all runners offline" nav alert (Option B). Requires
  `view_runners`; returns `false` for a subject with no account or without the
  permission — i.e. no badge. A bare boolean, matching the sidebar count badges.
  """
  def fleet_all_offline?(%Subject{account: %{id: account_id}} = subject) do
    case Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runners_permission()) do
      :ok ->
        count_billable_runners(account_id) > 0 and map_size(connection_metas(account_id)) == 0

      _ ->
        false
    end
  end

  def fleet_all_offline?(%Subject{}), do: false

  @doc """
  Whether the account's whole active fleet is signed-only — there's at least one
  billable (active, non-disabled) runner and every one of them advertises
  `enforce_signatures`, so the portal can't dispatch to any of them. Drives the
  runners-index "fleet is signed-only" notice. Requires `view_runners`; returns
  `false` for a subject with no account or without the permission. A bare boolean.
  """
  def fleet_all_signed?(%Subject{account: %{id: account_id}} = subject) do
    case Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runners_permission()) do
      :ok ->
        active =
          Runner.Query.not_deleted()
          |> Runner.Query.not_disabled()
          |> Runner.Query.by_account_id(account_id)

        total = Repo.aggregate(active, :count, :id)
        total > 0 and Repo.aggregate(Runner.Query.enforcing(active), :count, :id) == total

      _ ->
        false
    end
  end

  def fleet_all_signed?(%Subject{}), do: false

  @doc """
  Derived connection state for a runner struct carrying the virtual
  `online?` field (set by `list_runners_for_account/2` and
  `fetch_runner_by_id/3` from presence). `:disabled` and `:pending`
  win over a stale socket so the operator UI reads true.
  """
  # No heartbeat-age `:stale` state by design — liveness is enforced at the
  # socket, not re-derived from `last_heartbeat_at`: the runner heartbeats every
  # 30s and ends its session on a failed send, and the portal closes the socket
  # after 90s with no heartbeat (EmisarWeb.RunnerSocket). A silent runner drops
  # to `:offline` within 90s rather than lingering "online but stale", so an
  # `online?` runner is one that has heartbeated recently — the binary is honest.
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
  Internal — scope resolver: all scope rows for a membership, ordered for
  stable rendering. Composed by `Runners` / `Runs.dispatch_run` (already
  authorized via Subject) and the team-page LV (operator's own membership
  in scope); no Subject because scoping is by the opaque `membership_id`
  the caller has already proven access to.
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
  Internal — scope batcher: `%{membership_id => [%UserRunnerScope{}]}` so
  an already-authorized list view renders scope chips without N+1 queries;
  takes opaque ids, no Subject.
  """
  def runner_scopes_for_membership_ids(ids) when is_list(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case ids do
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
      {preloads, opts} = Keyword.pop(opts, :preload, [])

      AuthKey.Query.visible_to_operators()
      |> AuthKey.Query.ordered_by_recent()
      |> apply_auth_key_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(AuthKey.Query, opts)
    end
  end

  # Rendering concerns are the caller's: pass `preload:` only for the
  # associations the page actually shows. Unknown atoms raise (caller bug).
  defp apply_auth_key_preloads(queryable, preloads) do
    Enum.reduce(preloads, queryable, fn
      :created_by, queryable -> AuthKey.Query.with_preloaded_created_by(queryable)
    end)
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
      |> Repo.commit_multi(after_commit: &broadcast_auth_key_created(&1.key))
      |> case do
        {:ok, %{key: key}} -> {:ok, raw, key}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -- PubSub ----------------------------------------------------------

  @doc "Subscribe the caller to this account's runner presence diffs."
  def subscribe_connections(account_id) do
    Emisar.PubSub.subscribe(Presence.topic(account_id))
  end

  @doc "Subscribe the caller to the account's auth-key list changes (`{:list_changed, :auth_key, …}`)."
  def subscribe_account_auth_keys(account_id),
    do: Emisar.PubSub.subscribe(account_auth_keys_topic(account_id))

  defp account_auth_keys_topic(account_id), do: "account:#{account_id}:auth_keys"

  defp broadcast_auth_key_created(%AuthKey{} = key) do
    Emisar.PubSub.broadcast(
      account_auth_keys_topic(key.account_id),
      {:list_changed, :auth_key, "auth_key.created", key.id}
    )
  end

  defp broadcast_auth_key_revoked(%AuthKey{} = key) do
    Emisar.PubSub.broadcast(
      account_auth_keys_topic(key.account_id),
      {:list_changed, :auth_key, "auth_key.revoked", key.id}
    )
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
  # Directed (single-consumer) publish — the runner's socket process is the
  # topic's only subscriber, so this is a "deliver", not a broadcast_* event.
  # credo:disable-for-lines:3 Emisar.Checks.InlineBroadcast
  def deliver_to_runner(account_id, runner_id, msg),
    do: Emisar.PubSub.broadcast(runner_topic(account_id, runner_id), {:cloud_to_runner, msg})

  # Force any LIVE socket for this runner to disconnect after disable/delete. The
  # socket authenticates ONLY at connect, so an already-connected (now disabled/
  # deleted) runner would otherwise keep finalizing in-flight runs + mutating the
  # pack-trust catalog until its socket happened to drop — Disable/Delete must be a
  # kill switch, not just a future-dispatch block. The socket stops on
  # `:runner_socket_revoked` (runner_socket.ex).
  defp broadcast_runner_revoked(%Runner{} = runner) do
    Emisar.PubSub.broadcast(runner_topic(runner.account_id, runner.id), :runner_socket_revoked)
  end

  defp runner_topic(account_id, runner_id), do: "account:#{account_id}:runner:#{runner_id}"

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

      Multi.new()
      # Insert first, then evict — so the account never momentarily has
      # zero auto-unused keys (which would race against concurrent
      # dashboard mounts).
      |> Multi.insert(
        :key,
        AuthKey.Changeset.mint_install(account_id, user_id, prefix, hash, %{})
      )
      |> Multi.run(:evicted, fn _repo, %{key: key} ->
        {:ok, evict_install_ring_overflow(account_id, cap, grace_s, key.auto_generated_at)}
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{key: key}} -> {:ok, raw, key}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp evict_install_ring_overflow(account_id, cap, grace_seconds, now) do
    protected_floor = DateTime.add(now, -grace_seconds, :second)

    AuthKey.Query.evictable_install_overflow(account_id, cap, protected_floor)
    |> Repo.delete_all()
  end

  # Revoking an already-revoked key is an idempotent no-op — re-stamping
  # revoked_at (plus a fresh audit row + broadcast) would move the revocation
  # time and pollute the trail. Still permission-gated so an unauthorized
  # caller is rejected, not silently OK'd.
  def revoke_auth_key(%AuthKey{revoked_at: revoked_at} = key, %Subject{} = subject)
      when not is_nil(revoked_at) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_auth_keys_permission()
           ) do
      {:ok, key}
    end
  end

  def revoke_auth_key(%AuthKey{} = key, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_auth_keys_permission()
           ) do
      by_user_id = Subject.actor_id(subject)

      AuthKey.Query.not_deleted()
      |> AuthKey.Query.by_id(key.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(AuthKey.Query,
        with: &AuthKey.Changeset.revoke(&1, by_user_id),
        audit: &Audit.Events.auth_key_revoked(subject, &1),
        after_commit: &broadcast_auth_key_revoked/1
      )
    end
  end

  @doc """
  Peeks at the presented raw secret, resolving it to an `%AuthKey{}`.
  Returns nil when there's no match or the key is unusable (revoked/
  deleted/expired/single-use exhausted). Constant-time hash comparison.
  `peek_*` per AGENTS.md §1.1 — nil-or-struct credential lookup.

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

      # Deliberately all(): `usable?/1` below is the single liveness gate
      # (it rejects deleted/revoked/expired/exhausted in one place).
      queryable = AuthKey.Query.all() |> AuthKey.Query.by_key_prefix(prefix)

      with %AuthKey{} = key <- Repo.peek(queryable),
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
  Internal — registration flow only: mints a long-lived per-runner token,
  persists the hash, returns `{raw_token, token_record}`. Establishes the
  runner identity before any Subject exists.
  """
  def mint_runner_token(%Runner{} = runner, issued_via_key_id \\ nil) do
    {raw, prefix, hash} = Crypto.mint("rnrtok-", @token_prefix_size)

    {:ok, token} =
      Token.Changeset.create(runner.id, issued_via_key_id, prefix, hash)
      |> Repo.insert()

    {raw, token}
  end

  @doc """
  Internal — runner socket upgrade controller, before any Subject exists:
  verifies a presented runner token. Returns `{:ok, token, runner}` or
  `{:error, :token_invalid}`.
  """
  def verify_runner_token(raw) when is_binary(raw) do
    if String.length(raw) < @token_prefix_size do
      {:error, :token_invalid}
    else
      prefix = String.slice(raw, 0, @token_prefix_size)
      hash = Crypto.hash(raw)
      token_queryable = Token.Query.all() |> Token.Query.by_prefix(prefix)

      with %Token{} = token <- Repo.peek(token_queryable),
           true <- Crypto.secure_compare(token.token_hash, hash),
           runner_queryable = Runner.Query.not_deleted() |> Runner.Query.by_id(token.runner_id),
           %Runner{disabled_at: nil} = runner <- Repo.peek(runner_queryable) do
        {:ok, _} = token |> Token.Changeset.usage() |> Repo.update()
        {:ok, token, runner}
      else
        _ -> {:error, :token_invalid}
      end
    end
  end

  # -- Authorization ---------------------------------------------------

  @doc "True when the subject may view the runner fleet (the console nav + section gate)."
  def subject_can_view_runners?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.view_runners_permission())

  @doc "Whether `subject` may manage runners (admin+)."
  def subject_can_manage_runners?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_runners_permission())

  @doc "Whether `subject` may manage runner auth keys (admin+)."
  def subject_can_manage_auth_keys?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_auth_keys_permission())

  # -- Registration (auth_key -> runner + token exchange) --------------

  @doc """
  Internal — runner-register controller, raw secret in hand (the secret IS
  the auth, no Subject yet exists): a runner presents a valid auth key on
  first connect. Creates the runner record (or returns the existing one
  for a reusable key) and mints a fresh per-runner token; enforces the
  account's runner-count plan limit.

  Returns `{:ok, runner, token, raw_token}` on success or
  `{:error, reason}` / `{:error, :over_limit, plan, limit}`.
  """
  def register_via_auth_key(raw_or_key, attrs, context \\ %RequestContext{})

  def register_via_auth_key(raw, attrs, context) when is_binary(raw) do
    case peek_auth_key_by_secret(raw) do
      nil -> {:error, :auth_key_invalid}
      %AuthKey{} = key -> register_via_auth_key(key, attrs, context)
    end
  end

  def register_via_auth_key(%AuthKey{} = key, attrs, context) do
    key = Repo.preload(key, :account)
    was_auto? = AuthKey.auto_unused?(key)
    external_id = registration_external_id(attrs)

    Multi.new()
    # Lock the account row FIRST so concurrent registrations for this account
    # serialize: the plan-limit count + insert below is a TOCTOU otherwise (two
    # runners both read `current < limit` and both insert, exceeding the ceiling).
    |> Multi.run(:lock_account, fn repo, _changes ->
      Accounts.fetch_and_lock_account(key.account_id, repo: repo)
    end)
    # Atomically claim a use of this auth key. The conditional UPDATE only
    # succeeds if the key is still usable AT the moment of the update —
    # defeating the race where two concurrent registrations both see
    # uses_count = 0.
    |> Multi.run(:consume, fn _repo, _changes ->
      case consume_auth_key(key) do
        :ok -> {:ok, :consumed}
        {:error, reason} -> {:error, reason}
      end
    end)
    # Surface the auto→permanent promotion. The mint itself is deliberately
    # silent (would flood the log), so binding is where the key first
    # becomes visible.
    |> maybe_audit_auth_key_bound(key, was_auto?)
    |> Multi.run(:registration, fn repo, _changes ->
      register_or_reuse_runner(repo, key, attrs, external_id)
    end)
    |> maybe_audit_runner_registered(key, context)
    |> Multi.run(:token, fn _repo, %{registration: {runner, _fresh?}} ->
      {:ok, mint_runner_token(runner, key.id)}
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{registration: {runner, _fresh?}, token: {raw_token, token}}} ->
        {:ok, runner, token, raw_token}

      {:error, {:over_limit, plan, limit}} ->
        {:error, :over_limit, plan, limit}

      {:error, {:runner_name_taken, name}} ->
        {:error, :runner_name_taken, name}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Identity is (account, external_id) — the stable id the runner persists
  # and sends. Names are display-only and may repeat across runners, so
  # external_id is the only uniqueness. A blank id (older runner that
  # doesn't send one) gets a server-minted UUID, never treated as a shared
  # empty-string key.
  defp registration_external_id(attrs) do
    case attrs[:external_id] do
      id when is_binary(id) and id != "" -> id
      _ -> Ecto.UUID.generate()
    end
  end

  defp maybe_audit_auth_key_bound(multi, _key, false), do: multi

  defp maybe_audit_auth_key_bound(multi, key, true),
    do: Multi.insert(multi, :auth_key_bound, Audit.Events.auth_key_bound(key))

  # Only a brand-new seat is audited as a registration — a reconnecting
  # runner that already has a row isn't.
  defp maybe_audit_runner_registered(multi, key, context) do
    Multi.run(multi, :registered_audit, fn repo, %{registration: {runner, fresh?}} ->
      if fresh?,
        do: repo.insert(Audit.Events.runner_registered(runner, key, context)),
        else: {:ok, nil}
    end)
  end

  # Reuse the existing row on reconnect; otherwise insert a new one. The
  # plan's runner-count limit is enforced only on the fresh-insert branch
  # and before the row exists (so the count excludes it). A reconnecting
  # runner — e.g. one that lost its token on a redeploy and re-registers
  # via its auth key — is already counted, so checking the limit for it
  # would lock an operator out of their own fleet at the plan ceiling.
  defp register_or_reuse_runner(repo, key, attrs, external_id) do
    case fetch_runner_by_external_id_for_account(external_id, key.account_id) do
      {:ok, %Runner{} = existing} ->
        {:ok, {existing, false}}

      {:error, :not_found} ->
        case Emisar.Billing.check_limit(key.account, :runners) do
          :ok -> insert_runner(repo, key, attrs, external_id)
          {:error, :over_limit, plan, limit} -> {:error, {:over_limit, plan, limit}}
        end
    end
  end

  # Insert a brand-new runner. `on_conflict: :nothing` on
  # (account, external_id) makes a concurrent register with the same id
  # a no-op instead of a constraint error that would poison the
  # transaction (Postgres 25P02); we then re-fetch the canonical row and
  # report whether *this* call inserted it. Returns `{:ok, {runner, fresh?}}`.
  #
  # The unique index is partial (`WHERE deleted_at IS NULL`) so a
  # soft-deleted runner frees its external_id — the conflict target has to
  # carry the same predicate or Postgres won't match the partial index.
  # An :unsafe_fragment is the only way to express that in Ecto; the
  # columns/predicate are literals here, so there's nothing to interpolate.
  defp insert_runner(repo, key, attrs, external_id) do
    name = derive_name(attrs)

    with :ok <- ensure_name_available(key, name) do
      changeset =
        Runner.Changeset.register(%{
          account_id: key.account_id,
          name: name,
          external_id: external_id,
          group: attrs[:group] || "default",
          hostname: attrs[:hostname],
          labels: attrs[:labels] || %{},
          runner_version: attrs[:version] || attrs[:runner_version],
          bootstrap_auth_key_id: key.id
        })

      case repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target:
               {:unsafe_fragment, "(account_id, external_id) WHERE deleted_at IS NULL"}
           ) do
        {:ok, inserted} ->
          {:ok, runner} = fetch_runner_by_external_id_for_account(external_id, key.account_id)
          {:ok, {runner, runner.id == inserted.id}}

        {:error, changeset} ->
          if name_taken_changeset?(changeset),
            do: {:error, {:runner_name_taken, name}},
            else: {:error, changeset}
      end
    end
  end

  # Names are unique among live runners: another live runner holding this
  # name — online or not — is a conflict the operator resolves (rename or
  # delete the holder in the dashboard). The partial unique index is the
  # race backstop in `insert_runner/4`.
  defp ensure_name_available(key, name) do
    taken? =
      Runner.Query.not_deleted()
      |> Runner.Query.by_account_id(key.account_id)
      |> Runner.Query.by_name(name)
      |> Repo.exists?()

    if taken?, do: {:error, {:runner_name_taken, name}}, else: :ok
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
    attrs[:hostname] || attrs[:name] || "runner-#{Crypto.runner_name_suffix()}"
  end
end
