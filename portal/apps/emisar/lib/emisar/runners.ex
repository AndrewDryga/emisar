defmodule Emisar.Runners do
  @moduledoc """
  Runner lifecycle: registration, enrollment-key management, token mint/verify,
  state advertisement persistence, connection state.

  Presence carries the runner's live UI state (`action_load`, last heartbeat).
  A short DB lease serializes transport ownership across portal nodes so two
  processes presenting one runner identity cannot both execute dispatches.

  Reads/writes go through `Runner.Query` + `Runner.Changeset` (and
  similar per-entity modules under `Emisar.Runners.EnrollmentKey`,
  `Token`). The public surface takes `%Subject{}` and
  routes through `Authorizer.for_subject/2`; the runner-socket-driven
  state helpers (`apply_state`, `connect_runner`, `disconnect_runner`,
  `record_heartbeat`) are internal
  to the runner connection process and called with the runner
  socket's own subject upstream.

  The context module also **supervises the Runners recurrent jobs** (the
  inactivity-retention sweep), the way `Emisar.Catalog`/`Emisar.Runs` do —
  domain jobs live under `jobs/` and their owning context starts them.
  """
  use Supervisor
  alias Ecto.Multi
  alias Emisar.{Accounts, Audit, Auth, Billing, Compat, Crypto, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.RequestContext
  alias Emisar.Runners.{Authorizer, ConnectionChange, EnrollmentKey, InactiveRetentionInput}
  alias Emisar.Runners.{Presence, Runner, Token}
  require Logger

  # 13 chars for "emkey-enroll-" + 16 random chars => 29.
  @enrollment_key_prefix_size 29
  # 7 chars for "rnrtok-" + 5 random.
  @token_prefix_size 12

  # Per-account ring cap for auto-generated, unused install keys.
  # Dashboard mounts mint into the ring; when capacity is exceeded the
  # oldest auto-unused entry is evicted (see `mint_install_key/2`).
  @install_ring_cap 42
  @install_eviction_grace_seconds 60
  @connection_lease_seconds 120

  # 90 days of life, refreshed once a token is two thirds through it. That
  # leaves 30 days and hundreds of reconnects for a refresh to succeed, so a
  # transient portal outage or a bad release cannot expire a fleet.
  @token_lifetime_seconds 90 * 24 * 3_600
  @token_refresh_after_seconds 60 * 24 * 3_600
  # The outgoing token stays usable this long after its successor is minted. A
  # runner that receives a successor and dies before persisting it still
  # reconnects on the old one and refreshes again.
  @token_retirement_grace_seconds 24 * 3_600

  # Matches EmisarWeb.RunnerSocket's heartbeat timeout: past this age the socket
  # is already closing the connection, so a stale reading is an imminent drop,
  # never a re-derived liveness verdict of our own.
  @heartbeat_stale_after_seconds 90

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      job_module("InactiveRunnerRetention")
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp job_module(name), do: Module.safe_concat([__MODULE__, "Jobs", name])

  # -- Runners: reads --------------------------------------------------

  @doc """
  Internal — label batcher: returns `%{runner_id => runner_name}` for the
  supplied ids. Composed by sibling contexts / audit / list pages that
  already authorized a parent listing (with its own Subject) and render
  labels for ids they already trust; no Subject by design.
  """
  def runner_labels_for_ids(account_id, ids) when is_binary(account_id) and is_list(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case ids do
      [] ->
        %{}

      ids ->
        # Deliberately all(), not not_deleted(): runs and audit rows keep
        # foreign keys to soft-deleted runners, and their labels must
        # still render in history views.
        #
        # `account_id` is required, not optional. Callers pass ids from rows
        # they already authorized, but the lookup itself had no tenant filter
        # at all — it would resolve ANY account's runner id to its name, which
        # is one careless caller away from a cross-tenant name leak. Its direct
        # analogue `Audit.resolve_references/1` scopes the same operation, and
        # so does the sibling `runner_scope_facts_for_ids/2` below.
        Runner.Query.all()
        |> Runner.Query.by_account_id(account_id)
        |> Runner.Query.select_labels(ids, :name)
        |> Repo.all()
        |> Map.new()
    end
  end

  @doc """
  Internal — bounded account-scoped facts for checking a previously authorized
  resource against current membership runner access. Missing or cross-account
  ids stay missing so the caller can fail closed.
  """
  def runner_scope_facts_for_ids(account_id, ids)
      when is_binary(account_id) and is_list(ids) and length(ids) <= 256 do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Runner.Query.all()
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.by_ids(ids)
    |> Runner.Query.select_scope_facts()
    |> Repo.all()
  end

  def runner_scope_facts_for_ids(_account_id, _ids), do: []

  @doc """
  Internal — the account facts one runner-access selection is allowlisted
  against: the distinct requested `groups` a live runner in `account_id`
  actually carries, plus `%{id, group}` for each requested runner id that
  exists there. Deleted rows and other accounts' runners resolve to nothing, so
  the caller rejects the ref rather than granting it.

  It answers only what the selection named — never a group's members, never the
  fleet — and is bounded at 256 refs total. Both lists must already be
  canonical (`Emisar.Accounts.RunnerAccess.selection_refs/1`): a malformed id
  must not reach the uuid parameter, so an invalid account, an invalid id, or
  an over-long selection fails closed with `{:error, :invalid_runner_scope}`.
  """
  def runner_selection_facts_for_account(account_id, groups, runner_ids)
      when is_binary(account_id) and is_list(groups) and is_list(runner_ids) and
             length(groups) + length(runner_ids) <= 256 do
    if Repo.valid_uuid?(account_id) and Enum.all?(runner_ids, &Repo.valid_uuid?/1) do
      {:ok,
       %{
         groups: existing_groups(account_id, groups),
         runners: exact_runner_facts(account_id, runner_ids)
       }}
    else
      {:error, :invalid_runner_scope}
    end
  end

  def runner_selection_facts_for_account(_account_id, _groups, _runner_ids),
    do: {:error, :invalid_runner_scope}

  defp existing_groups(_account_id, []), do: []

  defp existing_groups(account_id, groups) do
    Runner.Query.not_deleted()
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.by_groups(groups)
    |> Runner.Query.select_distinct_groups()
    |> Repo.all()
  end

  defp exact_runner_facts(_account_id, []), do: []

  defp exact_runner_facts(account_id, runner_ids) do
    Runner.Query.not_deleted()
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.by_ids(runner_ids)
    |> Runner.Query.select_scope_facts()
    |> Repo.all()
  end

  @doc "The Runners table's `%Repo.Filter{}` list."
  def runner_filters, do: Runner.Query.filters()

  @doc """
  Paginated, filterable runner listing for the RunnersLive UI —
  `:group` / `:status` opts narrow the set. The authenticated subject's
  runner access applies in the query before pagination: `none` returns no rows,
  `all` is unrestricted, and `restricted` filters by stored groups and ids.
  Pass `preload: [:online?]` when the caller renders live connection facts.
  Returns `{:ok, [runner], %Paginator.Metadata{}}`. MCP paths that need the
  complete accessible fleet use `list_all_runners_for_account/2` instead.
  """
  def list_runners_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runners_permission()
           ) do
      {group, opts} = Keyword.pop(opts, :group)
      {status, opts} = Keyword.pop(opts, :status)

      Runner.Query.not_deleted()
      |> Runner.Query.ordered_by_group_name()
      |> maybe_by_group(group)
      |> maybe_by_connection(subject, status)
      |> scope_to_subject_membership(subject)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Runner.Query, opts)
    end
  end

  @doc """
  Every non-deleted runner visible to the subject's membership — the COMPLETE
  scoped set, deliberately un-paginated. Pass `preload: [:online?]` when the
  caller needs live connection facts.

  The MCP path: `tools/list`, dispatch resolution, and runner
  inventory must see every accessible runner (no status/group filter), not a
  page. The UI uses the paginated
  `list_runners_for_account/2`. Returns `{:ok, runners}`.
  """
  def list_all_runners_for_account(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runners_permission()
           ) do
      preloads = Keyword.get(opts, :preload, [])

      runners =
        Runner.Query.not_deleted()
        |> Runner.Query.ordered_by_group_name()
        |> scope_to_subject_membership(subject)
        |> Authorizer.for_subject(subject)
        |> Repo.all()
        |> apply_runner_preloads(preloads)

      {:ok, runners}
    end
  end

  @doc """
  `{:ok, [{runner_id, name}]}` for the subject's complete visible fleet, sorted
  by name. Selects only the two stable fields a runner dropdown renders and
  never reads Presence. Requires `view_runners`.
  """
  def list_runner_options(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runners_permission()
           ) do
      options =
        Runner.Query.not_deleted()
        |> Runner.Query.ordered_by_name()
        |> Runner.Query.select_options()
        |> scope_to_subject_membership(subject)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, options}
    end
  end

  @doc """
  Bounded pack-advertisement facts for the subject's current visible runners:
  each non-deleted runner's `%{id, name, group, packs}`, ordered by group then
  name. The Catalog composes it to answer which hosts are on a pack version
  from the durable runner_state advertisement (an installed pack may advertise
  no actions, so action rows cannot answer it). Requires `view_runners`.

  `limit` is required and caps the read. Returns
  `{:ok, facts, %{coverage: :complete | :partial}}` — `:partial` when the
  subject cannot see the whole account fleet or their visible fleet has more
  runners than `limit`, so a caller can never read a short scoped list as "no
  runner is on it".
  """
  def list_pack_advertisement_facts(limit, %Subject{} = subject)
      when is_integer(limit) and limit > 0 do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runners_permission()
           ) do
      access = Accounts.runner_access_for_subject(subject)

      # One row past the cap is the sentinel that says the visible fleet
      # overflows it. Restricted reach is inherently partial account coverage,
      # even when every visible row fits.
      facts =
        Runner.Query.not_deleted()
        |> Runner.Query.ordered_by_group_name()
        |> Runner.Query.select_pack_advertisement_facts()
        |> scope_to_runner_access(access)
        |> Authorizer.for_subject(subject)
        |> Runner.Query.limit_to(limit + 1)
        |> Repo.all()

      partial? = length(facts) > limit or access.mode != :all
      coverage = if partial?, do: :partial, else: :complete

      {:ok, Enum.take(facts, limit), %{coverage: coverage}}
    end
  end

  @doc "Resolves several strict targets through one bounded, scoped fleet read."
  def resolve_runbook_target_sets(targets, %Subject{} = subject) when is_list(targets) do
    with {:ok, runners} <- list_all_runners_for_account(subject, preload: [:online?]) do
      available = available_runbook_targets(runners)

      targets
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn
        {%{"selection" => selection, "refs" => refs}, index}, {:ok, selected}
        when selection in ["all", "random_one"] and is_list(refs) ->
          case select_runbook_target_runners(refs, available) do
            {:ok, target_runners} ->
              target_set = %{
                selection: selection,
                refs: refs,
                runners: target_runners,
                group: selected_group(selection, refs)
              }

              {:cont, {:ok, [target_set | selected]}}

            {:error, :unknown_target} ->
              {:halt, {:error, {:unknown_target, index}}}
          end

        {_target, index}, _selected ->
          {:halt, {:error, {:unknown_target, index}}}
      end)
      |> case do
        {:ok, selected} -> {:ok, Enum.reverse(selected)}
        {:error, {:unknown_target, _index}} = error -> error
      end
    end
  end

  @doc "The stable readable runner reference owned by the runner identity domain."
  def public_ref(%Runner{name: name, external_id: external_id})
      when is_binary(name) and is_binary(external_id) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z/, name) and
         byte_size(external_id) in 1..256 do
      digest = external_id |> Crypto.hash_hex() |> binary_part(0, 32)
      {:ok, name <> "~" <> digest}
    else
      {:error, :invalid_runner}
    end
  end

  def public_ref(_runner), do: {:error, :invalid_runner}

  @doc """
  Internal — the pure target facts an already-scoped runner list currently
  offers a runbook: every enabled, online runner with a representable public
  ref. Both dispatch resolution and the authoring editor project targets from
  this one list, so an offline or unrepresentable runner is never selectable in
  either.
  """
  def available_runbook_targets(runners) when is_list(runners) do
    runners
    |> Enum.filter(&(connection_state(&1) == :online))
    |> Enum.flat_map(&runbook_runner/1)
  end

  @doc """
  Internal — resolves tagged `group:` / `runner:` refs against available target
  facts. Every ref must resolve, so a partial target never silently shrinks the
  blast radius. Returns `{:ok, [target]} | {:error, :unknown_target}`.
  """
  def select_runbook_target_runners(refs, available) when is_list(refs) and is_list(available) do
    grouped = Enum.group_by(available, & &1.group)
    by_ref = Map.new(available, &{&1.runner_ref, &1})

    selected =
      Enum.reduce_while(refs, [], fn
        "group:" <> group, selected ->
          case Map.fetch(grouped, group) do
            {:ok, runners} -> {:cont, runners ++ selected}
            :error -> {:halt, :unknown_target}
          end

        "runner:" <> ref, selected ->
          case Map.fetch(by_ref, ref) do
            {:ok, runner} -> {:cont, [runner | selected]}
            :error -> {:halt, :unknown_target}
          end

        _ref, _selected ->
          {:halt, :unknown_target}
      end)

    case selected do
      :unknown_target ->
        {:error, :unknown_target}

      selected ->
        selected =
          selected
          |> Enum.uniq_by(& &1.id)
          |> Enum.sort_by(& &1.runner_ref)

        {:ok, selected}
    end
  end

  defp runbook_runner(%Runner{disabled_at: nil} = runner) do
    case public_ref(runner) do
      {:ok, runner_ref} ->
        [
          %{
            id: runner.id,
            runner_ref: runner_ref,
            name: runner.name,
            group: runner.group,
            enforce_signatures: runner.enforce_signatures,
            runner: runner
          }
        ]

      {:error, :invalid_runner} ->
        []
    end
  end

  defp runbook_runner(%Runner{}), do: []

  defp selected_group("random_one", ["group:" <> group]), do: group
  defp selected_group(_selection, _refs), do: nil

  # Membership access is current authorization data, not session state. Resolve
  # the active membership before every runner query so suspension, deletion, and
  # access changes immediately affect open sessions and old API keys.
  defp scope_to_subject_membership(query, %Subject{} = subject) do
    scope_to_runner_access(query, Accounts.runner_access_for_subject(subject))
  end

  defp scope_to_runner_access(query, access) do
    case access do
      %Accounts.RunnerAccess{mode: :none} ->
        Runner.Query.none(query)

      %Accounts.RunnerAccess{mode: :all} ->
        query

      %Accounts.RunnerAccess{mode: :restricted, runner_ids: runner_ids, groups: groups} ->
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
        |> scope_to_subject_membership(subject)
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
      |> scope_to_subject_membership(subject)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runner.Query, opts)
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
      |> scope_to_subject_membership(subject)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runner.Query, opts)
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
    |> Runner.Query.with_active_account()
    |> Runner.Query.by_id(runner_id)
    |> Runner.Query.by_account_id(account_id)
    |> Repo.exists?()
  end

  @doc """
  Internal — the Policies scoped-override gate: true when `runner_id` is a
  non-deleted runner in `account_id`. Unlike `runner_active_in_account?/2`,
  a disabled runner counts — its policy override stays editable while the
  runner is offline. A malformed id is false. Pass `repo:` to join an open
  transaction.
  """
  def runner_in_account?(runner_id, account_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    if Repo.valid_uuid?(runner_id) do
      Runner.Query.not_deleted()
      |> Runner.Query.by_id(runner_id)
      |> Runner.Query.by_account_id(account_id)
      |> repo.exists?()
    else
      false
    end
  end

  @doc """
  Internal — true when any of `runner_ids` is a runner in `account_id` that
  registered with `enrollment_key_id` as its bootstrap key. The install wizard checks
  this on a presence join so it only advances when the runner minted from THIS
  page's key connects — not any runner that happens to join the account's
  presence (a reconnect, another host coming up).
  """
  def any_runner_bootstrapped_by_key?(runner_ids, enrollment_key_id, account_id)
      when is_list(runner_ids) and is_binary(enrollment_key_id) and is_binary(account_id) do
    Runner.Query.not_deleted()
    |> Runner.Query.by_ids(runner_ids)
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.by_bootstrap_enrollment_key_id(enrollment_key_id)
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
    Runner.Query.not_deleted()
    |> Runner.Query.connection_counts()
    |> Repo.one()
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
  `register_via_enrollment_key/2`; not exposed to LiveView/MCP — they don't
  have an external_id at the auth boundary.
  """
  def fetch_runner_by_external_id_for_account(external_id, account_id, opts \\ [])
      when is_binary(external_id) do
    repo = Keyword.get(opts, :repo, Repo)

    Runner.Query.not_deleted()
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.by_external_id(external_id)
    |> repo.fetch(Runner.Query)
  end

  @doc """
  Internal — locks an active runner for a caller's transaction. Catalog state
  ingestion holds this lock through its write so disable/delete serializes with
  the last in-flight advertisement instead of letting a revoked runner mutate
  the catalog after the lifecycle change commits.
  """
  def fetch_and_lock_active_runner(runner_id, account_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    Runner.Query.not_deleted()
    |> Runner.Query.not_disabled()
    |> Runner.Query.by_id(runner_id)
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.lock_for_update()
    |> repo.fetch(Runner.Query)
  end

  @doc """
  Internal — locks and returns a runner only when the supplied socket still
  owns its durable connection lease. Call inside the same transaction as an
  inbound socket mutation so a successor claim cannot race the write.
  """
  def fetch_and_lock_connection_owner(
        account_id,
        runner_id,
        generation,
        lease_id,
        opts \\ []
      ) do
    repo = Keyword.get(opts, :repo, Repo)

    Runner.Query.not_deleted()
    |> Runner.Query.not_disabled()
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.by_id(runner_id)
    |> Runner.Query.by_connection_lease(generation, lease_id)
    |> Runner.Query.lock_for_update()
    |> repo.fetch(Runner.Query)
  end

  # -- Runners: mutations ----------------------------------------------

  def disable_runner(%Runner{} = runner, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runners_permission()
           ) do
      Runner.Query.not_deleted()
      |> Runner.Query.by_id(runner.id)
      |> scope_to_subject_membership(subject)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Runner.Query,
        with: &Runner.Changeset.disable/1,
        audit: &Audit.Events.runner_disabled(subject, &1),
        after_commit: &broadcast_runner_disabled/1
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
        case Billing.check_limit(subject.account, :runners) do
          :ok -> {:ok, :ok}
          {:error, :over_limit, plan, limit} -> {:error, {:over_limit, plan, limit}}
        end
      end)
      |> Multi.run(:runner, fn _repo, _ ->
        Runner.Query.not_deleted()
        |> Runner.Query.by_id(runner.id)
        |> scope_to_subject_membership(subject)
        |> Authorizer.for_subject(subject)
        |> Repo.fetch_and_update(Runner.Query, with: &Runner.Changeset.enable/1)
      end)
      # The audit row belongs to the OUTER multi, not the nested
      # fetch_and_update's `:audit`: a nested call joins this transaction and
      # returns before it commits, so its broadcast would announce
      # `runner.enabled` to subscribers even when this commit later fails.
      # Inserted here it commits with the enable, and commit_multi broadcasts it
      # once — after the only commit there is.
      |> Multi.insert(:audit, fn %{runner: enabled} ->
        Audit.Events.runner_enabled(subject, enabled)
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
      |> scope_to_subject_membership(subject)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Runner.Query,
        with: &Runner.Changeset.delete/1,
        audit: &Audit.Events.runner_deleted(subject, &1),
        after_commit: &broadcast_runner_revoked/1
      )
    end
  end

  # -- Retention -------------------------------------------------------

  @doc """
  Changeset for the account's runner-cleanup settings — the raw `hours` window,
  where a blank value means automatic cleanup is off. Accepts the rail form's
  string keys or an atom-keyed map / keyword list; a malformed or non-positive
  window is a field error. Pure.
  """
  def change_inactive_retention_settings(attrs \\ %{}),
    do: InactiveRetentionInput.changeset(attrs)

  @doc """
  Set how long a runner may stay cleanly offline before the hourly sweep
  soft-deletes it. Requires `manage_runners` AND unrestricted runner access —
  the schedule is account-wide, so a runner-scoped admin must not arm a sweep
  that reaches past their own scope — and `account` must be the subject's own.
  `attrs` is validated through `change_inactive_retention_settings/1` before
  anything is written, so an invalid window never reaches the stored setting; a
  blank window turns automatic cleanup off. Returns
  `{:ok, %Accounts.Account{}}` or
  `{:error, %Ecto.Changeset{} | :unauthorized | :not_found}`.
  """
  def update_inactive_retention_settings(
        %Accounts.Account{} = account,
        attrs,
        %Subject{} = subject
      ) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runners_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, account.id),
         :ok <- ensure_full_runner_access(subject),
         {:ok, %InactiveRetentionInput{hours: hours}} <- inactive_retention_input(attrs) do
      Accounts.put_account_runner_inactive_retention_hours(account.id, hours, subject)
    end
  end

  defp ensure_full_runner_access(%Subject{} = subject) do
    if full_runner_access?(subject), do: :ok, else: {:error, :unauthorized}
  end

  @doc """
  What the account's stored cleanup setting means right now — `{:ok, hours}`
  while automatic cleanup is on, `{:error, :retention_disabled}` when it is off
  or the stored window is not a usable positive number. Takes the account (the
  job sweep's row) or its settings (the operator sweep's fresh read). Both
  sweeps read the setting through here, so one contract decides when a
  destructive sweep may run.
  """
  def inactive_retention_hours(%Accounts.Account{settings: settings}),
    do: inactive_retention_hours(settings)

  def inactive_retention_hours(%Accounts.Account.Settings{} = settings) do
    case inactive_retention_input(%{hours: settings.runner_inactive_retention_hours}) do
      {:ok, %InactiveRetentionInput{hours: hours}} when is_integer(hours) -> {:ok, hours}
      {:ok, %InactiveRetentionInput{}} -> {:error, :retention_disabled}
      {:error, %Ecto.Changeset{}} -> {:error, :retention_disabled}
    end
  end

  defp inactive_retention_input(attrs) do
    attrs
    |> change_inactive_retention_settings()
    |> Ecto.Changeset.apply_action(:insert)
  end

  @doc """
  Run the inactivity-retention sweep for the subject's account right now — the
  runners page "Clean up now" button. Uses the account's configured window
  (`settings.runner_inactive_retention_hours`); `{:error, :retention_disabled}`
  when automatic cleanup is off. Requires `manage_runners`. Returns
  `{:ok, deleted_count}`.
  """
  def sweep_inactive_runners(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runners_permission()
           ),
         {:ok, hours} <- fetch_inactive_retention_hours(subject) do
      delete_inactive_runners(subject.account.id, hours, subject)
    end
  end

  # The subject's account struct is a socket snapshot — read the setting fresh.
  defp fetch_inactive_retention_hours(%Subject{account: %{id: account_id}}) do
    with {:ok, settings} <- Accounts.fetch_account_settings(account_id) do
      inactive_retention_hours(settings)
    end
  end

  @doc """
  Internal — the inactivity-retention sweep for one account: the daily
  `Runners.Jobs.InactiveRunnerRetention` tick (no subject → system audit actor,
  account-wide) and `sweep_inactive_runners/1` (operator actor, narrowed to that
  operator's runner access). Soft-deletes every in-scope runner cleanly offline
  for `hours` hours — durably disconnected with a last disconnect older than the
  cutoff — and records ONE `runner.retention_swept` audit event only when
  something was removed. Returns `{:ok, deleted_count}`.

  Conservative by construction: a currently-connected runner (a later
  `last_connected_at`), a never-connected runner, and a disabled runner (a
  deliberate reversible park) are all excluded, so the sweep only removes hosts
  that connected and have since stayed gone.
  """
  def delete_inactive_runners(account_id, hours, subject \\ nil)
      when is_binary(account_id) and is_integer(hours) and hours > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3_600, :second)

    Multi.new()
    |> Multi.run(:runners, fn repo, _changes ->
      queryable =
        Runner.Query.not_deleted()
        |> Runner.Query.by_account_id(account_id)
        |> Runner.Query.not_disabled()
        |> Runner.Query.disconnected()
        |> Runner.Query.last_disconnected_before(cutoff)
        |> scope_sweep_to_subject(subject)
        |> Runner.Query.lock_for_update()

      {:ok, repo.all(queryable)}
    end)
    |> Multi.run(:deleted, fn repo, %{runners: runners} ->
      now = DateTime.utc_now()

      queryable =
        Runner.Query.all()
        |> Runner.Query.by_ids(Enum.map(runners, & &1.id))

      {count, _} = repo.update_all(queryable, set: [deleted_at: now, updated_at: now])
      {:ok, count}
    end)
    |> Multi.run(:audit, fn repo, %{runners: runners} ->
      record_inactivity_sweep(repo, runners, hours, subject)
    end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{deleted: deleted}} -> {:ok, deleted}
      {:error, reason} -> {:error, reason}
    end
  end

  # No marker when nothing was removed — scheduled housekeeping must not
  # manufacture audit noise on inactive accounts.
  defp record_inactivity_sweep(_repo, [], _hours, _subject), do: {:ok, :nothing_removed}

  defp record_inactivity_sweep(repo, runners, hours, subject) do
    actor = subject || hd(runners).account_id
    repo.insert(Audit.Events.runner_retention_swept(actor, runners, hours))
  end

  # The manual "Clean up now" sweep is narrowed to the operator's own runner
  # access, exactly as delete_runner is — a runner-scope-restricted admin must
  # not delete beyond their scope. The nightly job passes no subject and stays
  # account-wide; an owner (or any all-access member) resolves to unrestricted.
  defp scope_sweep_to_subject(queryable, %Subject{} = subject),
    do: scope_to_subject_membership(queryable, subject)

  defp scope_sweep_to_subject(queryable, nil), do: queryable

  @doc """
  Internal — every runner whose advertised packs still matter, for pack
  retention.

  Deliberately NOT the connected set. Disable is a reversible park (see
  `shared-runner-lifecycle-states`), and a disconnected runner reconnects — but
  the retention sweep read `list_connected_runners_for_account/2`, so parking a
  runner for maintenance eventually hard-deleted its `catalog_pack_versions`
  rows INCLUDING the trusted ones. Re-enabling then left every pack `:pending`
  and dispatch failing closed until an admin re-reviewed each hash, with nothing
  having warned that a reversible action cost that.

  A merely DISCONNECTED runner is not shielded — that case ages out exactly as
  before — and neither is a deleted one.
  """
  def list_pack_referencing_runners_for_account(account_id, opts \\ [])
      when is_binary(account_id) do
    repo = Keyword.get(opts, :repo, Repo)

    Runner.Query.not_deleted()
    |> Runner.Query.connected_or_disabled()
    |> Runner.Query.by_account_id(account_id)
    |> repo.all()
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
    |> active_runner_query()
    |> update_runner_state(payload)
  end

  @doc """
  Internal — applies a runner-state advertisement only while this socket owns
  the matching generation and lease. The lease predicate is locked with the
  update, closing the preflight-check handoff race.
  """
  def apply_state_from_connection(
        %Runner{} = runner,
        %{} = payload,
        generation,
        lease_id
      ) do
    runner
    |> active_runner_query()
    |> Runner.Query.by_connection_lease(generation, lease_id)
    |> update_runner_state(payload)
  end

  defp active_runner_query(%Runner{} = runner) do
    Runner.Query.not_deleted()
    |> Runner.Query.not_disabled()
    |> Runner.Query.by_account_id(runner.account_id)
    |> Runner.Query.by_id(runner.id)
  end

  defp update_runner_state(query, payload) do
    Repo.fetch_and_update(query, Runner.Query,
      with: fn active_runner ->
        Runner.Changeset.apply_state(active_runner, %{
          hostname: payload["hostname"] || active_runner.hostname,
          labels: payload["labels"] || active_runner.labels,
          runner_version: payload["version"] || active_runner.runner_version,
          packs: payload["packs"] || active_runner.packs,
          # `group` is RUNNER-DECLARED: a config `runner.group` rename reaches the
          # cloud here on reconnect, so update it (keep the existing group when the
          # payload's is missing/blank — never wipe to ""). Deliberately trusted:
          # group selects which policy override governs dispatches to THIS runner
          # (Policies.resolve_policy), so a compromised host could declare a looser
          # group — but it already owns the box the runner executes on, so it gains
          # nothing it couldn't do locally. The host is the trust anchor. Pin to the
          # enrollment key if you need it operator-authoritative. See .agent/kb/specs/security-model.md.
          group: nonblank(payload["group"]) || active_runner.group,
          # Runner-declared too, but trusting it is unconditionally safe: it only
          # makes the runner STRICTER (refuse unsigned dispatch), never looser. A
          # missing/false value clears it, so flipping enforcement off in config
          # propagates on the next reconnect.
          enforce_signatures: payload["enforce_signatures"] == true,
          # The freshness window the runner advertises when enforcing; nil clears it.
          max_attestation_age_seconds: payload["max_attestation_age_seconds"],
          # Packs the runner's loader skipped, so the console and MCP can say
          # "pack X failed to load on runner Y". Normalized here — display
          # text from a hostile authenticated runner — and self-clearing: an
          # advertisement without the field (or an older runner) resets to [].
          degraded_packs: normalize_degraded_packs(payload["degraded_packs"])
        })
      end
    )
  end

  # Keep only well-shaped entries, bound their sizes, and cap the list — the
  # payload is runner-controlled display text.
  @max_degraded_packs 32
  defp normalize_degraded_packs(entries) when is_list(entries) do
    entries
    |> Enum.filter(&valid_degraded_pack?/1)
    |> Enum.take(@max_degraded_packs)
    |> Enum.map(fn %{"pack" => pack, "reason" => reason} ->
      %{"pack" => String.slice(pack, 0, 80), "reason" => String.slice(reason, 0, 500)}
    end)
  end

  defp normalize_degraded_packs(_absent), do: []

  defp valid_degraded_pack?(%{"pack" => pack, "reason" => reason}),
    do: is_binary(pack) and pack != "" and is_binary(reason) and reason != ""

  defp valid_degraded_pack?(_entry), do: false

  defp nonblank(value) when is_binary(value) and value != "", do: value
  defp nonblank(_), do: nil

  @doc """
  Internal — called by the runner socket on connect. Claims the connection
  lease (writing the `runner.connected` audit row in the same transaction, so
  a failed claim leaves no audit), tracks the socket process in presence (the
  live "online" signal), and stamps `last_connected_at` for the durable
  "last seen" history. A presence-track failure releases the claim again via
  `disconnect_runner`, so the audit trail stays an honest connect/disconnect pair.
  """
  def connect_runner(%Runner{} = runner, token_id \\ nil, context \\ %RequestContext{}) do
    now = DateTime.utc_now()
    lease_id = Ecto.UUID.generate()
    lease_expires_at = DateTime.add(now, @connection_lease_seconds, :second)

    result =
      Runner.Query.not_deleted()
      |> Runner.Query.not_disabled()
      |> Runner.Query.with_active_account()
      |> Runner.Query.by_id(runner.id)
      |> Runner.Query.by_account_id(runner.account_id)
      |> Runner.Query.lease_available(now)
      |> Repo.fetch_and_update(Runner.Query,
        with: &Runner.Changeset.connected(&1, lease_id, lease_expires_at),
        audit: &Audit.Events.runner_connected(&1, token_id, context)
      )

    with {:ok, claimed} <- normalize_connection_claim(result, runner) do
      meta = %{
        online_at: System.system_time(:second),
        action_load: 0,
        last_heartbeat_at: nil,
        connection_generation: claimed.connection_generation,
        connection_lease_id: claimed.connection_lease_id,
        node: node()
      }

      # An expired owner may still be alive on a partitioned node. Fence it as
      # soon as the durable claim changes; every inbound frame also verifies the
      # lease before it may mutate state.
      broadcast_runner_superseded(claimed)

      case Presence.track(self(), Presence.topic(claimed.account_id), claimed.id, meta) do
        {:ok, _ref} ->
          {:ok, claimed}

        {:error, reason} ->
          Logger.warning("presence track failed for runner #{claimed.id}: #{inspect(reason)}")
          _ = release_connection(claimed, "presence track failed", context)
          {:error, {:presence, reason}}
      end
    end
  end

  defp normalize_connection_claim({:error, :not_found}, runner) do
    case Accounts.fetch_account_by_id_or_slug_including_disabled(runner.account_id) do
      {:ok, %{disabled_at: %DateTime{}}} ->
        {:error, :account_disabled}

      _ ->
        if runner_active_in_account?(runner.id, runner.account_id) do
          {:error, :already_connected}
        else
          {:error, :not_found}
        end
    end
  end

  defp normalize_connection_claim(result, _runner), do: result

  @doc """
  Internal — disconnect a socket only if it still owns the active lease,
  writing the `runner.disconnected` audit row in the same transaction. A
  superseded lease is `{:error, :not_found}` and leaves no audit — a stale
  socket must never stamp its successor disconnected.
  """
  def disconnect_runner(
        runner_id,
        connection_generation,
        lease_id,
        reason,
        context \\ %RequestContext{}
      )
      when is_binary(runner_id) and is_integer(connection_generation) and is_binary(lease_id) do
    Runner.Query.not_deleted()
    |> Runner.Query.by_id(runner_id)
    |> Runner.Query.by_connection_lease(connection_generation, lease_id)
    |> Repo.fetch_and_update(Runner.Query,
      with: &Runner.Changeset.disconnected(&1, reason),
      audit: &Audit.Events.runner_disconnected(&1.account_id, &1.id, reason, context)
    )
  end

  defp release_connection(%Runner{} = runner, reason, context) do
    disconnect_runner(
      runner.id,
      runner.connection_generation,
      runner.connection_lease_id,
      reason,
      context
    )
  end

  @doc """
  Internal — renews the socket's ownership lease and refreshes its Presence
  metadata. A superseded socket gets `{:error, :not_found}` and must close.
  """
  def record_heartbeat(account_id, runner_id, generation, lease_id, action_load) do
    queryable =
      Runner.Query.not_deleted()
      |> Runner.Query.not_disabled()
      |> Runner.Query.by_account_id(account_id)
      |> Runner.Query.by_id(runner_id)
      |> Runner.Query.by_connection_lease(generation, lease_id)

    with {:ok, _runner} <- renew_connection_lease(queryable) do
      Presence.update(self(), Presence.topic(account_id), runner_id, fn meta ->
        %{
          meta
          | action_load: action_load || meta.action_load,
            last_heartbeat_at: System.system_time(:second)
        }
      end)
    end
  end

  # A heartbeat arrives every 30s against a 120s lease, so writing a fresh
  # expiry on each one re-locked and rewrote the runner row twice a minute per
  # connected host — the standing write load on an otherwise idle deployment,
  # for a value that was not close to lapsing. The lease is renewed once it
  # reaches half its life, which still leaves two whole heartbeat intervals of
  # slack before it could expire; earlier beats only re-read the row to confirm
  # this socket still owns the identity, taking no lock and writing nothing.
  defp renew_connection_lease(queryable) do
    now = DateTime.utc_now()

    case Repo.peek(queryable) do
      nil ->
        {:error, :not_found}

      %Runner{} = runner ->
        if lease_renewal_due?(runner, now) do
          lease_expires_at = DateTime.add(now, @connection_lease_seconds, :second)

          Repo.fetch_and_update(queryable, Runner.Query,
            with: &Runner.Changeset.renew_connection(&1, lease_expires_at)
          )
        else
          {:ok, runner}
        end
    end
  end

  defp lease_renewal_due?(%Runner{connection_lease_expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.diff(expires_at, now, :second) <= div(@connection_lease_seconds, 2)

  defp lease_renewal_due?(%Runner{}, _now), do: true

  @doc "Internal — true only while the supplied socket still owns this runner identity."
  def connection_owner?(account_id, runner_id, generation, lease_id) do
    Runner.Query.not_deleted()
    |> Runner.Query.not_disabled()
    |> Runner.Query.by_account_id(account_id)
    |> Runner.Query.by_id(runner_id)
    |> Runner.Query.by_connection_lease(generation, lease_id)
    |> Repo.exists?()
  end

  @doc """
  Internal — runner socket: judge the runner's advertised version against the
  configured minimum. Rejection is a domain outcome carrying the minimum for
  the operator-facing close message, with its `runner.version_rejected` audit
  row recorded here — the transport only maps it to a shutdown frame.
  Enforcement drops only a version that parses AND is below the minimum;
  `:unknown` (missing/malformed), `:outdated`, and `:supported` all proceed,
  as does warn-only mode.
  """
  def enforce_runner_version(%Runner{} = runner, %RequestContext{} = context) do
    if Compat.enforce_runners?() and Compat.runner_status(runner.runner_version) == :unsupported do
      minimum = Compat.runner_minimum()
      # Fire-and-forget — the rejection stands even if the audit insert fails.
      _ = Audit.record(Audit.Events.runner_version_rejected(runner, minimum, context))
      {:error, {:unsupported_version, minimum}}
    else
      :ok
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
  Derived connection state for a runner struct carrying the virtual
  `online?` field (requested with `preload: [:online?]` on runner reads).
  `:disabled` wins over stale presence metadata; a never-connected runner with
  no presence is `:pending`.
  """
  # No heartbeat-age `:stale` state by design — liveness is enforced at the
  # socket, not re-derived from `last_heartbeat_at`: the runner heartbeats every
  # 30s and ends its session on a failed send, and the portal closes the socket
  # after 90s with no heartbeat (EmisarWeb.RunnerSocket). A silent runner drops
  # to `:offline` within 90s rather than lingering "online but stale", so an
  # `online?` runner is one that has heartbeated recently — the binary is honest.
  # `runner_readiness/2` reports heartbeat age as its OWN advisory fact, beside
  # this state rather than folded into it.
  def connection_state(%Runner{disabled_at: %DateTime{}}), do: :disabled
  def connection_state(%Runner{online?: true}), do: :online
  def connection_state(%Runner{last_connected_at: nil}), do: :pending
  def connection_state(%Runner{}), do: :offline

  @doc """
  Pure readiness projection for one presence-decorated runner — the stable facts
  every operator surface classifies on, each carrying an explicit reason atom so
  the web picks wording instead of re-deriving posture from raw columns:

    * `:connection` — `connection_state/1`'s atom plus why it holds
    * `:heartbeat` — heartbeat freshness, judged ONLY while presence says the
      runner is online (an offline row's last heartbeat is history, not
      liveness); `#{@heartbeat_stale_after_seconds}s` matches the socket's own
      heartbeat timeout, and the timestamps stay on the fact so a caller can
      render them
    * `:signatures` — whether the runner refuses unsigned dispatch
    * `:degradation` — the packs its loader skipped, as advertised
    * `:portal_dispatch` — what the portal may do right now: `:disabled` and
      signature enforcement block first, then the connection state decides.
      Stale heartbeats and degraded packs are advisory and never change it

  `now` is injectable so a caller can project a fixed instant.
  """
  def runner_readiness(runner, now_or_access \\ DateTime.utc_now())

  def runner_readiness(%Runner{} = runner, %Accounts.RunnerAccess{} = access) do
    degraded_packs =
      Enum.filter(runner.degraded_packs || [], fn
        %{"pack" => pack_id} -> Accounts.RunnerAccess.pack_in_scope?(pack_id, access)
        _malformed -> false
      end)

    runner_readiness(%{runner | degraded_packs: degraded_packs}, DateTime.utc_now())
  end

  def runner_readiness(%Runner{} = runner, %DateTime{} = now) do
    connection = readiness_connection(runner)
    signatures = readiness_signatures(runner)

    %{
      runner_id: runner.id,
      connection: connection,
      heartbeat: readiness_heartbeat(runner, connection, now),
      signatures: signatures,
      degradation: readiness_degradation(runner),
      portal_dispatch: readiness_portal_dispatch(connection, signatures),
      action_load: readiness_action_load(runner.action_load)
    }
  end

  @doc """
  Pure fleet projection over an ALREADY-scoped runner list: every runner's
  `runner_readiness/2` rolled into counts, one fleet-wide signature mode, and
  the stable reason atoms a surface turns into copy.

  Connection and portal-dispatch counts partition the whole list. `stale`,
  `signed_only`, `degraded`, and `degraded_packs` cover only the ACTIVE
  (non-disabled) runners — a disabled runner's posture isn't actionable — and
  `signature_mode` is computed over that same active set, so a disabled
  non-enforcing runner can't keep a fleet from reading signed-only.
  """
  def fleet_status(runners, now \\ DateTime.utc_now()) when is_list(runners) do
    readiness = Enum.map(runners, &runner_readiness(&1, now))
    {active, disabled} = Enum.split_with(readiness, &(&1.connection.state != :disabled))
    build_fleet_status(fleet_counts(readiness, active, disabled))
  end

  @doc """
  The subject's complete scoped fleet as one `fleet_status/2` projection,
  counted in the database — the nav, the runners index, and the fleet-dependent
  nudges all ask on common paths, so no runner row is materialized. The
  `view_runners` permission, the membership's CURRENT runner access, and the
  Authorizer's account scope all apply, so a runner the caller can't see never
  reaches the counts; Presence stays the authority on who is online and whose
  heartbeat has aged out. `:now` projects a fixed instant. Returns
  `{:ok, status} | {:error, :unauthorized}`.
  """
  def fetch_fleet_status(subject, opts \\ [])

  def fetch_fleet_status(%Subject{account: %{id: account_id}} = subject, opts) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runners_permission()
           ) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      metas = connection_metas(account_id)

      aggregate =
        Runner.Query.not_deleted()
        |> scope_to_subject_membership(subject)
        |> Runner.Query.fleet_status(Map.keys(metas), stale_heartbeat_ids(metas, now))
        |> Authorizer.for_subject(subject)
        |> Repo.one()

      {:ok, build_fleet_status(aggregate_counts(aggregate))}
    end
  end

  def fetch_fleet_status(%Subject{}, _opts), do: {:error, :unauthorized}

  defp readiness_connection(%Runner{} = runner) do
    state = connection_state(runner)
    %{state: state, reason: connection_reason(state)}
  end

  defp connection_reason(:disabled), do: :disabled
  defp connection_reason(:online), do: :presence_online
  defp connection_reason(:pending), do: :never_connected
  defp connection_reason(:offline), do: :presence_absent

  defp readiness_heartbeat(%Runner{last_heartbeat_at: nil} = runner, %{state: :online}, _now),
    do: heartbeat_fact(runner, :awaiting_first, :awaiting_first_heartbeat)

  defp readiness_heartbeat(%Runner{last_heartbeat_at: at} = runner, %{state: :online}, now) do
    if DateTime.diff(now, at, :second) >= @heartbeat_stale_after_seconds do
      heartbeat_fact(runner, :stale, :heartbeat_stale)
    else
      heartbeat_fact(runner, :fresh, :heartbeat_recent)
    end
  end

  defp readiness_heartbeat(%Runner{} = runner, _connection, _now),
    do: heartbeat_fact(runner, :unavailable, :not_online)

  defp heartbeat_fact(%Runner{} = runner, state, reason) do
    %{
      state: state,
      reason: reason,
      at: runner.last_heartbeat_at,
      connected_at: runner.last_connected_at
    }
  end

  defp readiness_signatures(%Runner{enforce_signatures: true}),
    do: %{mode: :signed_only, reason: :signature_required}

  defp readiness_signatures(%Runner{}),
    do: %{mode: :unsigned_allowed, reason: :unsigned_allowed}

  defp readiness_degradation(%Runner{degraded_packs: []}),
    do: %{state: :healthy, reason: :all_packs_loaded, packs: []}

  defp readiness_degradation(%Runner{degraded_packs: packs}),
    do: %{state: :degraded, reason: :degraded_packs, packs: packs}

  defp readiness_portal_dispatch(%{state: :disabled}, _signatures),
    do: %{state: :blocked, reason: :disabled}

  defp readiness_portal_dispatch(_connection, %{mode: :signed_only}),
    do: %{state: :blocked, reason: :signature_required}

  defp readiness_portal_dispatch(%{state: :online}, _signatures),
    do: %{state: :ready, reason: :online}

  defp readiness_portal_dispatch(%{state: :offline}, _signatures),
    do: %{state: :queueable, reason: :offline}

  defp readiness_portal_dispatch(%{state: :pending}, _signatures),
    do: %{state: :queueable, reason: :pending}

  defp readiness_action_load(load) when is_integer(load) and load >= 0, do: load
  defp readiness_action_load(_load), do: 0

  defp fleet_counts(readiness, active, disabled) do
    %{
      total: length(readiness),
      active: length(active),
      online: count_connection(readiness, :online),
      offline: count_connection(readiness, :offline),
      pending: count_connection(readiness, :pending),
      disabled: length(disabled),
      stale: Enum.count(active, &(&1.heartbeat.state == :stale)),
      signed_only: Enum.count(active, &(&1.signatures.mode == :signed_only)),
      degraded: Enum.count(active, &(&1.degradation.state == :degraded)),
      degraded_packs: Enum.sum_by(active, &length(&1.degradation.packs)),
      portal_ready: count_dispatch(readiness, :ready),
      portal_queueable: count_dispatch(readiness, :queueable),
      portal_blocked: count_dispatch(readiness, :blocked)
    }
  end

  defp count_connection(readiness, state),
    do: Enum.count(readiness, &(&1.connection.state == state))

  defp count_dispatch(readiness, state),
    do: Enum.count(readiness, &(&1.portal_dispatch.state == state))

  # The list projection and the database aggregate both stop at counts, so the
  # signature mode and the reason atoms are derived once — the two paths cannot
  # answer the same fleet differently.
  defp build_fleet_status(counts) do
    signature_mode = fleet_signature_mode(counts)

    %{
      counts: counts,
      signature_mode: signature_mode,
      reasons: fleet_reasons(counts, signature_mode)
    }
  end

  # Presence carries the heartbeat, so staleness is resolved here and handed to
  # the aggregate as an id list. A runner that has never heartbeated is awaiting
  # its first one, never stale — matching `runner_readiness/2`.
  defp stale_heartbeat_ids(metas, now) do
    for {runner_id, %{metas: [_ | _] = runner_metas}} <- metas,
        meta = latest_connection_meta(runner_metas),
        stale_heartbeat?(Map.get(meta, :last_heartbeat_at), now),
        do: runner_id
  end

  defp stale_heartbeat?(nil, _now), do: false

  defp stale_heartbeat?(unix, now) when is_integer(unix) do
    DateTime.to_unix(now) - unix >= @heartbeat_stale_after_seconds
  end

  defp stale_heartbeat?(_invalid, _now), do: false

  # Lease reclamation can briefly leave the old and new socket metas under one
  # Presence key. Presence does not promise list order, so prefer the newest
  # connection generation, then its newest heartbeat/online timestamp.
  defp latest_connection_meta(metas) do
    Enum.max_by(metas, fn meta ->
      {
        integer_meta(meta, :connection_generation),
        integer_meta(meta, :last_heartbeat_at),
        integer_meta(meta, :online_at)
      }
    end)
  end

  defp integer_meta(meta, key) do
    case Map.get(meta, key) do
      value when is_integer(value) -> value
      _invalid -> -1
    end
  end

  # SQL counts what a row can answer; the rest is arithmetic over those, in the
  # same shape `fleet_counts/3` builds from readiness facts. Among active
  # runners, signed-only is blocked and the unsigned remainder splits into
  # online (ready) and absent-presence (queueable).
  defp aggregate_counts(row) do
    active = row.total - row.disabled

    %{
      total: row.total,
      active: active,
      online: row.online,
      offline: row.total - row.online - row.pending - row.disabled,
      pending: row.pending,
      disabled: row.disabled,
      stale: row.stale,
      signed_only: row.signed_only,
      degraded: row.degraded,
      degraded_packs: row.degraded_packs,
      portal_ready: row.portal_ready,
      portal_queueable: active - row.signed_only - row.portal_ready,
      portal_blocked: row.disabled + row.signed_only
    }
  end

  defp fleet_signature_mode(%{active: 0}), do: :empty
  defp fleet_signature_mode(%{signed_only: 0}), do: :unsigned_allowed
  defp fleet_signature_mode(%{active: active, signed_only: active}), do: :signed_only
  defp fleet_signature_mode(_counts), do: :mixed

  # Stable atoms, never copy: each names one fleet-wide fact a surface explains.
  defp fleet_reasons(%{total: 0}, _signature_mode), do: [:fleet_empty]

  defp fleet_reasons(counts, signature_mode) do
    facts = [
      {counts.online > 0, :runners_online},
      {counts.online == 0 and counts.active > 0, :no_runners_online},
      {counts.stale > 0, :stale_heartbeats},
      {signature_mode == :signed_only, :fleet_signed_only},
      {signature_mode == :mixed, :mixed_signature_modes},
      {counts.degraded > 0, :degraded_packs}
    ]

    for {applies?, reason} <- facts, applies?, do: reason
  end

  @doc """
  Whether the subject can see ANY active runner — sequences fleet-dependent
  nudges. An existence check, not a fleet projection: it stops at the first
  matching row and never touches Presence. Fails closed without `view_runners`.
  """
  def any_runners?(%Subject{} = subject) do
    case Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runners_permission()) do
      :ok ->
        queryable =
          Runner.Query.not_deleted()
          |> Runner.Query.not_disabled()
          |> scope_to_subject_membership(subject)
          |> Authorizer.for_subject(subject)

        Repo.exists?(queryable)

      {:error, _reason} ->
        false
    end
  end

  @doc """
  Normalizes a broadcast from `subscribe_connections/1` into the connection
  facts a subscriber projects. Presence spells a heartbeat as the same runner
  leaving with its old metadata and joining with its new one, so metadata
  updates are separated from real connects and disconnects here; anything that
  isn't a presence diff yields the empty change.
  """
  def normalize_connection_change(event), do: ConnectionChange.normalize(event)

  @doc "Whether a change contains a real connect or disconnect, not just refreshed metadata."
  def connection_topology_changed?(change), do: ConnectionChange.topology_changed?(change)

  @doc "Ids of the runners that connected in this change — metadata updates are not joins."
  def joined_runner_ids(change), do: ConnectionChange.joined_runner_ids(change)

  @doc """
  Applies a change to a `%Runner{}`'s virtual connection fields. A disconnect
  clears `action_load` and `last_heartbeat_at` with it; a runner the change
  doesn't name is returned untouched.
  """
  def project_runner_connection(%Runner{} = runner, change),
    do: ConnectionChange.project_runner(runner, change)

  @doc "Applies a change to one runner's local connection atom, or keeps the current one."
  def project_connection(current, runner_id, change),
    do: ConnectionChange.project_connection(current, runner_id, change)

  @doc "Internal — virtual `:online?` preload callback for runner reads."
  def preload_runners_presence([]), do: []

  def preload_runners_presence(runners) when is_list(runners) do
    metas_by_account =
      runners
      |> Enum.map(& &1.account_id)
      |> Enum.uniq()
      |> Map.new(fn account_id -> {account_id, connection_metas(account_id)} end)

    Enum.map(runners, fn runner ->
      put_connection_meta(runner, get_in(metas_by_account, [runner.account_id, runner.id]))
    end)
  end

  defp apply_runner_preloads(runners, preloads) do
    Enum.reduce(List.wrap(preloads), runners, fn
      :online?, runners -> preload_runners_presence(runners)
    end)
  end

  defp put_connection_meta(runner, %{metas: [_ | _] = metas}) do
    meta = latest_connection_meta(metas)

    %{
      runner
      | online?: true,
        action_load: Map.get(meta, :action_load, 0),
        last_heartbeat_at: unix_to_datetime(Map.get(meta, :last_heartbeat_at))
    }
  end

  defp put_connection_meta(runner, _absent), do: %{runner | online?: false}

  defp unix_to_datetime(nil), do: nil

  defp unix_to_datetime(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp unix_to_datetime(_invalid), do: nil

  @doc """
  True when a runner is visible/dispatchable under explicit runner access.
  Membership structs are re-resolved by account and id; missing or inactive
  memberships fail closed.
  """
  def runner_in_scope?(_runner, nil), do: false

  def runner_in_scope?(runner, %Accounts.Membership{} = membership) do
    access = Accounts.runner_access_for_membership(membership.account_id, membership.id)
    Accounts.RunnerAccess.runner_in_scope?(runner, access)
  end

  def runner_in_scope?(runner, %Accounts.RunnerAccess{} = access),
    do: Accounts.RunnerAccess.runner_in_scope?(runner, access)

  def runner_in_scope?(_runner, _access), do: false

  # -- Enrollment keys -------------------------------------------------------

  @doc "The enrollment-keys table's `%Repo.Filter{}` list."
  def enrollment_key_filters, do: EnrollmentKey.Query.filters()

  def list_enrollment_keys(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_enrollment_keys_permission()
           ) do
      {preloads, opts} = Keyword.pop(opts, :preload, [])

      # The FULL inventory on purpose — a wizard-minted enrollment key is a
      # live root-capable credential; hiding it under-reported the very list
      # an operator audits (and the only place it can be revoked pre-use).
      EnrollmentKey.Query.not_deleted()
      |> EnrollmentKey.Query.ordered_by_recent()
      |> apply_enrollment_key_preloads(preloads)
      |> Authorizer.for_subject(subject)
      |> Repo.list(EnrollmentKey.Query, opts)
    end
  end

  # Rendering concerns are the caller's: pass `preload:` only for the
  # associations the page actually shows. Unknown atoms raise (caller bug).
  defp apply_enrollment_key_preloads(queryable, preloads) do
    Enum.reduce(preloads, queryable, fn
      :created_by, queryable -> EnrollmentKey.Query.with_preloaded_created_by(queryable)
    end)
  end

  @doc """
  Changeset for the enrollment-key create form (operator-facing fields, no secret
  minted). Drives `phx-change` validation + inline field errors in the
  LiveView; the real key is minted by `create_enrollment_key/2`.
  """
  def change_enrollment_key(attrs \\ %{}), do: EnrollmentKey.Changeset.form(attrs)

  def create_enrollment_key(attrs, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_enrollment_keys_permission()
           ) do
      account_id = account.id
      user_id = Subject.actor_id(subject)
      {raw, prefix, hash} = Crypto.mint("emkey-enroll-", @enrollment_key_prefix_size)

      Multi.new()
      |> Multi.insert(
        :key,
        EnrollmentKey.Changeset.create(account_id, user_id, prefix, hash, attrs)
      )
      |> Multi.insert(:audit, fn %{key: key} ->
        Audit.Events.enrollment_key_created(subject, key)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_enrollment_key_created(&1.key))
      |> case do
        {:ok, %{key: key}} -> {:ok, raw, key}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  The host install one-liner for a freshly minted enrollment key —
  `{:ok, command}`, or `{:error, :invalid_enrollment_key}` /
  `{:error, :invalid_base_url}` when an input isn't the exact shape a pasteable
  command may carry. Pure: reads nothing, writes nothing, logs nothing.
  """
  def enrollment_install_command(raw_secret, base_url) do
    with :ok <- validate_enrollment_secret(raw_secret),
         {:ok, base} <- normalize_base_url(base_url) do
      # Leading space keeps the key out of shell history under
      # HISTCONTROL=ignorespace / HIST_IGNORE_SPACE.
      {:ok,
       " curl -sSL #{base}/install.sh | sudo EMISAR_ENROLLMENT_KEY=#{raw_secret} EMISAR_URL=#{base} bash"}
    end
  end

  # Exactly what `Crypto.mint("emkey-enroll-", …)` produces: the tag plus the
  # url-safe-base64 tail of 32 random bytes. Anything else never reaches argv.
  defp validate_enrollment_secret(raw_secret) when is_binary(raw_secret) do
    if Regex.match?(~r/\Aemkey-enroll-[A-Za-z0-9_-]{43}\z/, raw_secret),
      do: :ok,
      else: {:error, :invalid_enrollment_key}
  end

  defp validate_enrollment_secret(_raw_secret), do: {:error, :invalid_enrollment_key}

  defp normalize_base_url(base_url) when is_binary(base_url) do
    base = String.replace_suffix(base_url, "/", "")

    case URI.new(base) do
      {:ok, uri} -> if plain_origin?(uri), do: {:ok, base}, else: {:error, :invalid_base_url}
      {:error, _part} -> {:error, :invalid_base_url}
    end
  end

  defp normalize_base_url(_base_url), do: {:error, :invalid_base_url}

  # A pasteable one-liner carries an origin and nothing else — no credentials,
  # no path/query/fragment, and no character a shell would act on.
  defp plain_origin?(%URI{
         scheme: scheme,
         userinfo: nil,
         host: host,
         port: port,
         path: path,
         query: nil,
         fragment: nil
       })
       when scheme in ["http", "https"] and is_binary(host) and is_integer(port) and
              port in 1..65_535 and path in [nil, ""] do
    Regex.match?(~r/\A[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\z/, host)
  end

  defp plain_origin?(_uri), do: false

  # -- PubSub ----------------------------------------------------------

  @doc "Subscribe the caller to this account's runner presence diffs."
  def subscribe_connections(account_id) do
    Emisar.PubSub.subscribe(Presence.topic(account_id))
  end

  @doc "Subscribe the caller to the account's enrollment-key list changes (`{:list_changed, :enrollment_key, …}`)."
  def subscribe_account_enrollment_keys(account_id),
    do: Emisar.PubSub.subscribe(account_enrollment_keys_topic(account_id))

  defp account_enrollment_keys_topic(account_id), do: "account:#{account_id}:enrollment_keys"

  defp broadcast_enrollment_key_created(%EnrollmentKey{} = key) do
    Emisar.PubSub.broadcast(
      account_enrollment_keys_topic(key.account_id),
      {:list_changed, :enrollment_key, "enrollment_key.created", key.id}
    )
  end

  defp broadcast_enrollment_key_revoked(%EnrollmentKey{} = key) do
    Emisar.PubSub.broadcast(
      account_enrollment_keys_topic(key.account_id),
      {:list_changed, :enrollment_key, "enrollment_key.revoked", key.id}
    )
  end

  @doc """
  Subscribe the caller to a runner's cloud→runner transport topic. Used
  by the runner socket process; messages arrive as
  `{:cloud_to_runner, generation, msg}`.
  """
  def subscribe_runner_transport(%Runner{} = runner) do
    :ok = Emisar.PubSub.subscribe(runner_topic(runner.account_id, runner.id))

    # Revocation is deliberately not generation-fenced: disabling/deleting a
    # runner must close every stale clone, not only the latest dispatch owner.
    Emisar.PubSub.subscribe(runner_control_topic(runner.account_id, runner.id))
  end

  @doc """
  Internal — Runs dispatch/cancel: push an outbound envelope to the
  runner's socket process. Callers must pass an account/runner pair already
  authorized by their owning operation.
  """
  # Directed (single-consumer) publish — the runner's socket process is the
  # topic's only subscriber, so this is a "deliver", not a broadcast_* event.
  # credo:disable-for-lines:3 Emisar.Checks.InlineBroadcast
  def deliver_to_runner(account_id, runner_id, generation, msg) do
    case current_connection_generation(account_id, runner_id) do
      {:ok, ^generation} -> broadcast_to_runner(account_id, runner_id, generation, msg)
      {:ok, _other_generation} -> {:error, :connection_changed}
      {:error, :not_connected} -> {:error, :not_connected}
    end
  end

  @doc "Internal — returns the generation currently authorized to receive dispatches."
  def current_connection_generation(account_id, runner_id) do
    runner =
      Runner.Query.not_deleted()
      |> Runner.Query.not_disabled()
      |> Runner.Query.with_active_account()
      |> Runner.Query.by_account_id(account_id)
      |> Runner.Query.by_id(runner_id)
      |> Repo.peek()

    if active_connection_lease?(runner),
      do: {:ok, runner.connection_generation},
      else: {:error, :not_connected}
  end

  defp active_connection_lease?(%Runner{
         connection_lease_id: lease_id,
         connection_lease_expires_at: expires_at
       })
       when is_binary(lease_id) and is_struct(expires_at, DateTime),
       do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  defp active_connection_lease?(_runner), do: false

  defp broadcast_to_runner(account_id, runner_id, generation, msg) do
    Emisar.PubSub.broadcast(
      runner_topic(account_id, runner_id),
      {:cloud_to_runner, generation, msg}
    )
  end

  defp broadcast_runner_superseded(%Runner{} = runner) do
    Emisar.PubSub.broadcast(
      runner_control_topic(runner.account_id, runner.id),
      {:runner_socket_superseded, runner.connection_lease_id}
    )
  end

  # Authentication runs only at connect, so either lifecycle change must drop the
  # live socket before it can finalize more runs or mutate catalog state. Disabled
  # retries its valid token; deleted revokes the identity and stops permanently.
  defp broadcast_runner_disabled(%Runner{} = runner) do
    Emisar.PubSub.broadcast(
      runner_control_topic(runner.account_id, runner.id),
      :runner_socket_disabled
    )
  end

  defp broadcast_runner_revoked(%Runner{} = runner) do
    Emisar.PubSub.broadcast(
      runner_control_topic(runner.account_id, runner.id),
      :runner_socket_revoked
    )
  end

  defp runner_topic(account_id, runner_id),
    do: "account:#{account_id}:runner:#{runner_id}"

  defp runner_control_topic(account_id, runner_id),
    do: "account:#{account_id}:runner:#{runner_id}:control"

  @doc """
  Mints a fresh, single-use bootstrap enrollment key for the dashboard's
  install command, marks it auto-generated, and evicts the oldest
  auto-unused key beyond the per-account ring cap of #{@install_ring_cap}.

  Returns `{:ok, raw_secret, key}`. No audit log on mint — auto-gen is
  noise. Once a runner registers with the key, `consume_enrollment_key/1`
  clears the auto flag and audit logs `enrollment_key.bound` with `auto: true`.
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

      {raw, prefix, hash} = Crypto.mint("emkey-enroll-", @enrollment_key_prefix_size)

      Multi.new()
      # Insert first, then evict — so the account never momentarily has
      # zero auto-unused keys (which would race against concurrent
      # dashboard mounts).
      |> Multi.insert(
        :key,
        EnrollmentKey.Changeset.mint_install(account_id, user_id, prefix, hash, %{})
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

    EnrollmentKey.Query.evictable_install_overflow(account_id, cap, protected_floor)
    |> Repo.delete_all()
  end

  # Revoking an already-revoked key is an idempotent no-op — re-stamping
  # revoked_at (plus a fresh audit row + broadcast) would move the revocation
  # time and pollute the trail. Still permission-gated so an unauthorized
  # caller is rejected, not silently OK'd.
  def revoke_enrollment_key(%EnrollmentKey{revoked_at: revoked_at} = key, %Subject{} = subject)
      when not is_nil(revoked_at) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_enrollment_keys_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, key.account_id) do
      {:ok, key}
    end
  end

  def revoke_enrollment_key(%EnrollmentKey{} = key, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_enrollment_keys_permission()
           ) do
      by_user_id = Subject.actor_id(subject)

      EnrollmentKey.Query.not_deleted()
      |> EnrollmentKey.Query.by_id(key.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(EnrollmentKey.Query,
        with: &EnrollmentKey.Changeset.revoke(&1, by_user_id),
        audit: &Audit.Events.enrollment_key_revoked(subject, &1),
        after_commit: &broadcast_enrollment_key_revoked/1
      )
    end
  end

  @doc """
  Peeks at the presented raw secret, resolving it to an `%EnrollmentKey{}`.
  Returns nil when there's no match or the key is unusable (revoked/
  deleted/expired/single-use exhausted). Constant-time hash comparison.
  `peek_*` per AGENTS.md §1.1 — nil-or-struct credential lookup.

  **Registration does NOT go through this.** `register_via_enrollment_key/3`
  resolves the secret with the same prefix+hash lookup and then claims a use
  *inside its transaction* (`EnrollmentKey.Query.consumable_by_id/2` +
  `consume_one/1`, a single guarded `update_all`), so the usability test is
  made by the database at the moment of the claim rather than read into memory
  first. That is the race-free order; the `EnrollmentKey.usable?/1` check here
  is the same question asked without the lock, and can go stale between the
  read and any write that follows it.

  So this is a read-only inspector: correct for answering "is this secret
  currently usable?", never a gate to act on.
  """
  def peek_enrollment_key_by_secret(raw) when is_binary(raw) do
    if String.length(raw) < @enrollment_key_prefix_size do
      nil
    else
      hash = Crypto.hash(raw)

      with %EnrollmentKey{} = key <- peek_by_prefix(raw, hash, @enrollment_key_prefix_size),
           true <- EnrollmentKey.usable?(key) do
        key
      else
        _ -> nil
      end
    end
  end

  defp peek_by_prefix(raw, hash, size) do
    if String.length(raw) < size do
      nil
    else
      prefix = String.slice(raw, 0, size)

      queryable = EnrollmentKey.Query.all() |> EnrollmentKey.Query.by_key_prefix(prefix)

      with %EnrollmentKey{} = key <- Repo.peek(queryable),
           true <- Crypto.secure_compare(key.key_hash, hash) do
        key
      else
        _ -> nil
      end
    end
  end

  # -- Per-runner tokens -----------------------------------------------

  @doc """
  Internal — registration flow only: mints a per-runner token,
  persists the hash, returns `{raw_token, token_record}`. Establishes the
  runner identity before any Subject exists.
  """
  def mint_runner_token(%Runner{} = runner, issued_via_key_id \\ nil, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    {raw, prefix, hash} = Crypto.mint("rnrtok-", @token_prefix_size)

    {:ok, token} =
      Token.Changeset.create(runner.id, issued_via_key_id, prefix, hash,
        lifetime_seconds: @token_lifetime_seconds
      )
      |> repo.insert()

    {raw, token}
  end

  @doc """
  Internal — the runner transport's `POST /runner/token/refresh`, before any
  Subject exists: exchange a live runner token for its successor.

  The presented token IS the authorization, exactly as it is for the socket
  upgrade. Returns `{:ok, raw_token, refresh_after}`, or `{:error, :not_due}`
  when the token is not old enough to rotate — a runner asking early is
  answered, not punished.

  The outgoing token is retired on a grace window rather than deleted, so a
  runner that receives a successor and then fails to persist it still has a
  working credential and refreshes again on the next connect. That property is
  what makes rotation safe to enable before expiry is enforced.
  """
  def refresh_runner_token(raw) when is_binary(raw) do
    case verify_runner_token(raw) do
      {:ok, %Token{} = token, %Runner{} = runner} ->
        if token_refresh_due?(token) do
          rotate_runner_token(token, runner)
        else
          {:error, :not_due}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rotate_runner_token(%Token{} = token, %Runner{} = runner) do
    Multi.new()
    |> Multi.run(:successor, fn repo, _changes ->
      {:ok, mint_runner_token(runner, token.issued_via_key_id, repo: repo)}
    end)
    |> Multi.update(
      :retired,
      Token.Changeset.retire_after(token, @token_retirement_grace_seconds)
    )
    |> Repo.commit_multi()
    |> case do
      {:ok, %{successor: {raw, token}}} -> {:ok, raw, token_refresh_after(token)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Internal — the runner transport: when this token becomes eligible for
  rotation, or nil for a token minted before rotation existed.

  The runner persists this and calls `/runner/token/refresh` once it has passed,
  so an ordinary reconnect costs no extra round-trip. Nil is not "never" — the
  client reads an absent value as "ask", which is how a pre-rotation token gets
  its first expiring successor.
  """
  def token_refresh_after(%Token{expires_at: nil}), do: nil

  def token_refresh_after(%Token{issued_at: issued_at}),
    do: DateTime.add(issued_at, @token_refresh_after_seconds, :second)

  # A token with no expiry predates rotation, and is exactly the one that has to
  # migrate onto an expiring credential — so it is due the moment it is asked
  # about. This is only ever reached because the runner called refresh, so a
  # client too old to refresh never gets a successor and cannot be stranded by
  # a clock it does not know how to reset.
  defp token_refresh_due?(%Token{expires_at: nil}), do: true

  defp token_refresh_due?(%Token{issued_at: issued_at}) do
    DateTime.diff(DateTime.utc_now(), issued_at, :second) >= @token_refresh_after_seconds
  end

  @doc """
  Internal — runner socket upgrade controller, before any Subject exists:
  verifies a presented runner token. Returns `{:ok, token, runner}`,
  `{:error, :runner_disabled}`, `{:error, :account_disabled}`,
  `{:error, :token_expired}`, or `{:error, :token_invalid}`.
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
           %Runner{} = runner <- Repo.peek(runner_queryable),
           :ok <- ensure_runner_and_account_enabled(runner),
           :ok <- ensure_token_not_expired(token) do
        {:ok, _} = token |> Token.Changeset.usage() |> Repo.update()
        {:ok, token, runner}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :token_invalid}
      end
    end
  end

  defp ensure_runner_and_account_enabled(%Runner{disabled_at: nil} = runner) do
    case Accounts.fetch_account_by_id_or_slug_including_disabled(runner.account_id) do
      {:ok, %{disabled_at: nil}} -> :ok
      {:ok, _disabled_account} -> {:error, :account_disabled}
      {:error, :not_found} -> {:error, :token_invalid}
    end
  end

  defp ensure_runner_and_account_enabled(%Runner{}), do: {:error, :runner_disabled}

  # A NULL expiry means never expires, and that is every token minted before
  # rotation shipped — its client has no refresh path, so enforcement must
  # leave it alone. Checked last, where the token would otherwise be accepted,
  # so a disabled runner or account keeps its own verdict and its own 403: a
  # 401 would tell the client to discard its token and re-register, which is
  # the wrong instruction for an identity an operator can simply re-enable.
  defp ensure_token_not_expired(%Token{expires_at: nil}), do: :ok

  defp ensure_token_not_expired(%Token{expires_at: expires_at}) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
      :ok
    else
      {:error, :token_expired}
    end
  end

  # -- Authorization ---------------------------------------------------

  @doc "True when the subject may view the runner fleet (the console nav + section gate)."
  def subject_can_view_runners?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.view_runners_permission())

  @doc "Whether `subject` may manage runners (admin+)."
  def subject_can_manage_runners?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_runners_permission())

  @doc "Whether the subject can mint an install key / connect a host (operators and above)."
  def subject_can_install_runners?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.issue_install_key_permission())

  @doc "Whether `subject` may manage runner enrollment keys (admin+)."
  def subject_can_manage_enrollment_keys?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_enrollment_keys_permission())

  @doc """
  Whether `subject` may change the account-wide inactivity window (the runners
  page's automatic-cleanup form) — `manage_runners` plus unrestricted runner
  access, since the schedule sweeps the whole fleet.
  """
  def subject_can_manage_inactive_retention?(%Subject{} = subject),
    do: subject_can_manage_runners?(subject) and full_runner_access?(subject)

  # Current access, re-read on every call: a narrowed scope takes the schedule
  # away from an open session immediately, and a stale snapshot never widens it.
  defp full_runner_access?(%Subject{} = subject) do
    case Accounts.runner_access_for_subject(subject) do
      %Accounts.RunnerAccess{mode: :all} -> true
      %Accounts.RunnerAccess{} -> false
    end
  end

  # -- Registration (enrollment_key -> runner + token exchange) --------------

  @doc """
  Internal — runner-register controller, raw secret in hand (the secret IS
  the auth, no Subject yet exists): a runner presents a valid enrollment key on
  first connect. Creates the runner record (or returns the existing one
  for a reusable key) and mints a fresh per-runner token; enforces the
  account's runner-count plan limit.

  Returns `{:ok, runner, token, raw_token}` on success or
  `{:error, reason}` / `{:error, :over_limit, plan, limit}`.
  """
  def register_via_enrollment_key(raw_or_key, attrs, context \\ %RequestContext{})

  def register_via_enrollment_key(raw, attrs, context) when is_binary(raw) do
    hash = Crypto.hash(raw)

    case peek_by_prefix(raw, hash, @enrollment_key_prefix_size) do
      nil -> {:error, :enrollment_key_invalid}
      %EnrollmentKey{} = key -> register_via_enrollment_key(key, attrs, context)
    end
  end

  def register_via_enrollment_key(%EnrollmentKey{} = key, attrs, context) do
    with {:ok, external_id} <- registration_external_id(attrs) do
      register_with_external_id(key, attrs, external_id, context)
    end
  end

  defp register_with_external_id(key, attrs, external_id, context) do
    key = Repo.preload(key, :account)
    was_auto? = EnrollmentKey.auto_unused?(key)

    Multi.new()
    # Lock the account row FIRST so concurrent registrations for this account
    # serialize: the plan-limit count + insert below is a TOCTOU otherwise (two
    # runners both read `current < limit` and both insert, exceeding the ceiling).
    |> Multi.run(:lock_account, fn repo, _changes ->
      Accounts.fetch_and_lock_account(key.account_id, repo: repo)
    end)
    # Atomically claim a use, or recognize the one narrow retry case: an
    # exhausted single-use key presented by the exact runner it already bound.
    |> Multi.run(:authorize_key, fn repo, _changes ->
      authorize_registration(repo, key, external_id)
    end)
    # Surface the auto→permanent promotion. The mint itself is deliberately
    # silent (would flood the log), so binding is where the key first
    # becomes visible.
    |> maybe_audit_enrollment_key_bound(key, was_auto?)
    |> Multi.run(:registration, fn repo, _changes ->
      register_or_reuse_runner(repo, key, attrs, external_id)
    end)
    |> maybe_audit_runner_registered(key, context)
    |> Multi.delete_all(:unused_tokens, fn %{registration: {runner, _fresh?}} ->
      Token.Query.all()
      |> Token.Query.by_runner_id(runner.id)
      |> Token.Query.by_issued_via_key_id(key.id)
      |> Token.Query.unused()
    end)
    |> Multi.run(:token, fn repo, %{registration: {runner, _fresh?}} ->
      {:ok, mint_runner_token(runner, key.id, repo: repo)}
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

  # Identity is (account, external_id) — the stable id the runner persists and
  # sends. Validate before the registration transaction so a malformed client
  # cannot consume its enrollment key and cannot acquire a different identity
  # on every retry.
  defp registration_external_id(%{external_id: external_id}) when is_binary(external_id) do
    if external_id != "" and String.trim(external_id) == external_id and
         String.length(external_id) <= 255 do
      {:ok, external_id}
    else
      {:error, :invalid_external_id}
    end
  end

  defp registration_external_id(_attrs), do: {:error, :invalid_external_id}

  defp maybe_audit_enrollment_key_bound(multi, _key, false), do: multi

  defp maybe_audit_enrollment_key_bound(multi, key, true),
    do: Multi.insert(multi, :enrollment_key_bound, Audit.Events.enrollment_key_bound(key))

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
  # via its enrollment key — is already counted, so checking the limit for it
  # would lock an operator out of their own fleet at the plan ceiling.
  defp register_or_reuse_runner(repo, key, attrs, external_id) do
    case fetch_runner_by_external_id_for_account(external_id, key.account_id, repo: repo) do
      {:ok, %Runner{} = existing} ->
        {:ok, {existing, false}}

      {:error, :not_found} ->
        case Billing.check_limit(key.account, :runners) do
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
          bootstrap_enrollment_key_id: key.id
        })

      case repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target:
               {:unsafe_fragment, "(account_id, external_id) WHERE deleted_at IS NULL"}
           ) do
        {:ok, inserted} ->
          {:ok, runner} =
            fetch_runner_by_external_id_for_account(external_id, key.account_id, repo: repo)

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
  defp authorize_registration(repo, key, external_id) do
    case consume_enrollment_key(repo, key) do
      :ok ->
        {:ok, :consumed}

      {:error, :enrollment_key_invalid} ->
        authorize_registration_retry(repo, key, external_id)
    end
  end

  defp authorize_registration_retry(repo, key, external_id) do
    now = DateTime.utc_now()
    key_queryable = EnrollmentKey.Query.all() |> EnrollmentKey.Query.by_id(key.id)

    with {:ok, current_key} <- repo.fetch(key_queryable, EnrollmentKey.Query),
         true <- registration_retry_key?(current_key, now),
         {:ok, runner} <-
           fetch_runner_by_external_id_for_account(external_id, current_key.account_id,
             repo: repo
           ),
         true <- runner.bootstrap_enrollment_key_id == current_key.id do
      {:ok, :retry}
    else
      _ -> {:error, :enrollment_key_invalid}
    end
  end

  defp registration_retry_key?(%EnrollmentKey{} = key, now) do
    not key.reusable and key.uses_count == 1 and is_nil(key.revoked_at) and
      is_nil(key.deleted_at) and
      (is_nil(key.expires_at) or DateTime.compare(now, key.expires_at) != :gt)
  end

  defp consume_enrollment_key(repo, %EnrollmentKey{} = key) do
    now = DateTime.utc_now()

    query =
      EnrollmentKey.Query.consumable_by_id(key.id, now)
      |> EnrollmentKey.Query.consume_one(now)

    case repo.update_all(query, []) do
      {1, _} -> :ok
      {0, _} -> {:error, :enrollment_key_invalid}
    end
  end

  defp derive_name(attrs) do
    attrs[:hostname] || attrs[:name] || "runner-#{Crypto.runner_name_suffix()}"
  end
end
