defmodule Emisar.Audit do
  @moduledoc """
  System-of-record audit log. Append-only; queryable by time, type,
  actor, subject. Distinct from `Runs.RunEvent` (progress chunks for
  one run) — `Audit.Event` is the human-facing "what happened?" log.

  ## Public read API

  Every read takes an `%Auth.Subject{}`. The Authorizer scopes the
  queryable to events the caller's account is allowed to see and gates
  on `view_audit_permission`.

  ## Write API

  `log/3` is an internal helper called from sibling contexts that have
  already authorized the parent action. It accepts `actor_kind`,
  `actor_id`, etc. as data rather than a subject because the caller
  already has the subject in hand and can derive those fields.

  ## Request metadata

  IP, user agent, request id, and MCP session are the inbound request's
  context. They ride in a `%RequestContext{}` passed via the `:context`
  attr key — from the caller's `%Subject{}` for an authenticated event
  (`Audit.Events` builders pull `subject.context` automatically), or
  explicitly on the pre-auth path. An event with no `:context` (system /
  engine origin) carries no request metadata, by construction.
  """
  use Supervisor
  alias Emisar.Audit.{Authorizer, Event, Events}
  alias Emisar.{Auth, Billing, Repo, RequestContext, Runs}
  alias Emisar.Auth.Subject

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    children = [job_module("Retention")]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp job_module(name), do: Module.safe_concat([__MODULE__, "Jobs", name])

  # -- Recording (internal helper called by sibling contexts) ----------

  @doc """
  Internal — sibling contexts call this inside their already-authorized
  mutation paths to append an audit event; subject-less because the acting
  subject is already captured in the event payload (`actor_kind` / `actor_id`
  are derived from the caller's `%Subject{}`).

  Use `changeset/3` instead when the audit row needs to commit
  atomically with a parent mutation (an `Ecto.Multi.insert/3` step).
  `log/3` is for fire-and-forget standalone events that have no parent
  transaction — sign-out, failed sign-in, runner heartbeat, etc.
  """
  def log(account_id, event_type, attrs \\ %{}) do
    Repo.insert(changeset(account_id, event_type, attrs))
  end

  @doc """
  Internal — sibling contexts call this from their already-authorized paths to
  insert a prebuilt `Audit.Events` changeset fire-and-forget; subject-less
  because the acting subject is already captured in the changeset. The
  counterpart to `log/3` for events whose actor/subject/payload fields come
  from a per-event builder rather than raw attrs (so the caller never
  hand-assembles them). Use an `Audit.Events.<event>` builder inside a
  `Multi.insert(:audit, …)` when the row must commit with a parent mutation;
  use this only for standalone socket/presence events that have no transaction
  to join (runner connect/disconnect/error). Like `log/3`, it does not
  broadcast — presence already drives the live runner UI.
  """
  def record(%Ecto.Changeset{} = event_changeset), do: Repo.insert(event_changeset)

  @doc """
  Build the audit-event changeset without inserting it — the low-level
  primitive the `Audit.Events` per-event builders sit on. Context
  mutations never call this directly: they go through an
  `Audit.Events.<event>/n` builder inside their `Multi` so the row
  commits or rolls back with the parent mutation and the actor fields
  derive from the `%Subject{}`:

      Multi.new()
      |> Multi.update(:policy, changeset)
      |> Multi.insert(:audit, fn %{policy: updated} ->
        Audit.Events.policy_updated(subject, updated)
      end)
      |> Repo.commit_multi()

  Field merge order is identical to `log/3`: base < request context
  < explicit attrs.
  """
  def changeset(account_id, event_type, attrs \\ %{}) do
    base = %{
      account_id: account_id,
      event_type: to_string(event_type),
      occurred_at: DateTime.utc_now()
    }

    # Request context rides in a `:context` `%RequestContext{}` — from the
    # caller's `%Subject{}` (via `actor/1`) or passed explicitly on the
    # pre-auth path. A struct, so the field set is fixed and a missing
    # context defaults to all-nil (system / engine origin → no metadata).
    {context, attrs} = Map.pop(normalize(attrs), :context, %RequestContext{})

    merged =
      base
      |> Map.merge(Map.from_struct(context))
      |> Map.merge(attrs)

    # Stamp the retention horizon from the FINAL occurred_at (attrs may backdate
    # it); an explicit `retain_until` in attrs wins.
    merged = Map.put_new(merged, :retain_until, retain_until(account_id, merged[:occurred_at]))

    Event.Changeset.create(merged)
  end

  # The row's delete horizon: occurred_at + the account's CURRENT plan retention
  # window, fixed at write time so a later plan downgrade can't retroactively prune
  # it (only future rows shrink). One plan lookup per audit write — cheap at this
  # system's action/auth-paced audit volume. A nil account_id / occurred_at can't
  # stamp (the changeset's required-field validation rejects the row anyway).
  defp retain_until(account_id, %DateTime{} = occurred_at) when is_binary(account_id) do
    DateTime.add(occurred_at, Billing.account_audit_retention_days(account_id) * 86_400, :second)
  end

  defp retain_until(_account_id, _occurred_at), do: nil

  @doc """
  Internal — sibling contexts (mostly Auth's pre-Subject flows) call this from
  their already-authorized paths to audit-log a user-scoped security event
  (sign-in, MFA, password change, profile edit); subject-less because the
  acting user is captured in the event itself. The user might not have a direct
  `account_id` in hand — most auth flows operate pre-Subject — so we look up the
  user's primary membership and stamp the event onto that account.

  Multi-account users only get the event on their primary membership
  in v0.1; widening to fan-out across every membership is a future
  call once we see whether it's needed.

  Silently no-ops when the user has no active membership (brand-new
  signup mid-account-creation, fully-suspended user) — the parent
  action either already audited, or there's no admin yet who could
  read it.

  `attrs` accepts the same shape as `log/3` and overrides the defaults
  (`actor_kind: "user", actor_id: user.id, target_kind: "user",
   target_id: user.id, target_label: user.email`).
  """
  def log_for_user(%Emisar.Users.User{} = user, event_type, attrs \\ %{}) do
    case user_changesets(user, event_type, attrs) do
      [] ->
        :ok

      # One row per account the user belongs to; commit them all-or-none. A
      # deliberate per-row insert (N = a user's membership count, tiny), inside a
      # txn — matching the prior no-broadcast standalone behaviour.
      changesets ->
        {:ok, _} = Repo.transaction(fn -> Enum.each(changesets, &Repo.insert!/1) end)
        :ok
    end
  end

  @doc """
  Audit-event changesets for a user-scoped event — ONE per active membership the
  user holds, since a row is `account_id`-scoped and each of the user's accounts
  legitimately sees its own copy (an account's owners must be able to see that a
  possibly-compromised member authenticated / disabled MFA / etc.). Build-only (no
  insert) so it composes into a parent transaction — `Repo.fetch_and_update`'s
  `:audit` and the `Audit.Multi` helpers insert the list atomically with the
  mutation. Returns `[]` (treated as "skip") when the user has no active membership.
  """
  def user_changesets(%Emisar.Users.User{} = user, event_type, attrs \\ %{}) do
    defaults = %{
      actor_kind: "user",
      actor_id: user.id,
      target_kind: "user",
      target_id: user.id,
      target_label: user.email
    }

    merged = Map.merge(defaults, normalize(attrs))

    user
    |> Emisar.Accounts.list_active_memberships_for_user()
    |> Enum.map(&changeset(&1.account_id, event_type, merged))
  end

  @doc """
  Build the audit-event changeset for a run state transition. Use
  inside an `Ecto.Multi` so the audit row commits together with the
  parent `run` update — see `Runs.transition/3`.
  """
  def run_event_changeset(%Runs.ActionRun{} = run) do
    changeset(
      run.account_id,
      "action_run.#{run.status}",
      run_target(run) ++
        [
          actor_kind: actor_kind(run),
          actor_id: run.requested_by_id || run.api_key_id,
          # Authoritative for the run's own events, including the terminal ones
          # logged from the runner-socket process (no request metadata there).
          # request_id is the action-dispatch id (req_…) — the meaningful
          # "request" for a run — promoted to a first-class field instead of
          # being buried in (and duplicated by) the payload.
          request_id: run.request_id,
          mcp_session_id: run.mcp_session_id,
          # The dispatcher's ip/ua, snapshotted on the run at create time — so even
          # the terminal event written from the runner-socket process (no inbound
          # request) attributes the action to its source, never the runner's socket.
          ip_address: run.ip_address,
          user_agent: run.user_agent,
          payload:
            compact(%{
              action: run.action_id,
              run_id: run.id,
              runbook_id: run.runbook_id,
              exit_code: run.exit_code,
              duration_ms: run.duration_ms,
              executed_command: run.executed_command,
              reason: run.reason_text,
              # Self-reported MCP client metadata snapshotted at dispatch, so a
              # terminal event logged long after (from the runner socket) still
              # carries it. Empty → dropped by compact, so non-MCP rows stay lean.
              mcp_client_metadata: mcp_client_metadata(run)
            })
        ]
    )
  end

  @doc """
  Target fields for any run-family event: the RUNNER the run executed on —
  the target answers "where did this happen", so an operator pivoting on it
  gets the host's whole history (connects, disables, every run). What ran
  (`action`) and the run's own id ride in the payload, and `request_id`
  groups the dispatch's full story. Shared by `run_event_changeset/1` and
  the `Audit.Events` run builders so the shape can't drift.
  """
  def run_target(%Runs.ActionRun{} = run) do
    [target_kind: "runner", target_id: run.runner_id, target_label: run_runner_name(run)]
  end

  # The runner's name for the write-time label stamp — one indexed point read
  # per audited transition when the assoc isn't loaded. `all()` on purpose (the
  # same label-resolver seam refs use): a just-soft-deleted runner still labels
  # its final events.
  defp run_runner_name(%Runs.ActionRun{runner: %Emisar.Runners.Runner{name: name}}), do: name
  defp run_runner_name(%Runs.ActionRun{runner_id: nil}), do: nil

  defp run_runner_name(%Runs.ActionRun{runner_id: id}) do
    labels =
      Emisar.Runners.Runner.Query.all()
      |> Emisar.Runners.Runner.Query.select_labels([id], :name)
      |> Repo.all()

    case labels do
      [{_id, name}] -> name
      _ -> nil
    end
  end

  # Drop nil-valued keys so audit rows for pending/sent runs don't
  # bloat with fields that are still being filled in.
  defp compact(map), do: :maps.filter(fn _key, value -> not is_nil(value) end, map)

  # Only carry self-reported metadata when the run actually has some — an empty
  # snapshot becomes nil so `compact/1` drops it from non-MCP payloads.
  defp mcp_client_metadata(%Runs.ActionRun{mcp_client_metadata: metadata})
       when map_size(metadata) > 0,
       do: metadata

  defp mcp_client_metadata(%Runs.ActionRun{}), do: nil

  defp actor_kind(%Runs.ActionRun{requested_by_id: id}) when not is_nil(id), do: "user"
  defp actor_kind(%Runs.ActionRun{api_key_id: id}) when not is_nil(id), do: "api_key"
  defp actor_kind(%Runs.ActionRun{source: :runbook}), do: "runbook"
  defp actor_kind(%Runs.ActionRun{source: :scheduled}), do: "scheduler"
  defp actor_kind(_), do: "system"

  # Internal helper — `log/3` accepts both atom and string keys to match
  # the loose Phoenix-form / API-payload shape callers happen to have.
  # `String.to_existing_atom/1` blows up loudly if a caller invents a
  # field name; sibling contexts only ever pass keys the Event
  # changeset already declares.
  defp normalize(attrs) do
    Enum.into(attrs, %{}, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  end

  # -- PubSub ----------------------------------------------------------

  @doc "Subscribe the caller to the account-wide audit fan-out (`{:audit_event, event}` per row)."
  def subscribe_account_audit(account_id),
    do: Emisar.PubSub.subscribe(account_audit_topic(account_id))

  defp account_audit_topic(account_id), do: "account:#{account_id}:audit"

  @doc """
  Internal — `Repo.commit_multi` auto-fans every committed `Audit.Event`
  to the account-wide audit topic, so AuditLive stays current without
  each context having to remember to broadcast.
  """
  def broadcast_event(%Event{} = event),
    do: Emisar.PubSub.broadcast(account_audit_topic(event.account_id), {:audit_event, event})

  # -- Reads (Subject-gated) -------------------------------------------

  @doc """
  Paginated + filterable list for the Audit page. Returns
  `{:ok, [event], %Paginator.Metadata{}} | {:error, ...}`. Honors
  `Emisar.Repo.list/3` options (`:filter`, `:page`).
  """
  def list_events(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_audit_permission()) do
      # actor_id / target_id ride as opts — the dynamic "by actor" / "by
      # subject" pickers aren't in the static filters/0 list, so they can't go
      # through :filter. Everything else is a LiveTable filter, applied via :filter.
      {actor_id, opts} = Keyword.pop(opts, :actor_id)
      {target_id, opts} = Keyword.pop(opts, :target_id)

      Event.Query.all()
      |> filter_by_actor_id(actor_id)
      |> filter_by_target_id(target_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Event.Query, opts)
    end
  end

  @doc """
  Distinct actors of `actor_kind` that appear in the account's audit log — the
  options for the page's on-demand actor filter, as `{id, label}` sorted by
  label (a bounded lookup, not a paginated list). Labels resolve cross-context
  the same way the table's actor column does; an id whose row is gone (deleted
  since the event, or only resolvable in another account) is dropped. Returns
  `{:ok, [{id, label}]}` or `{:error, :unauthorized}`.

  `opts[:ensure]` forces an actor id into the option set even with zero events
  (a Team "View activity" link for a member who hasn't acted yet), so the picker
  can SELECT it instead of falling back to All. An id that resolves to no label
  (not a member of this account) is still dropped.
  """
  def list_actor_options(actor_kind, %Subject{} = subject, opts \\ [])
      when is_binary(actor_kind) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_audit_permission()) do
      logged_ids =
        Event.Query.all()
        |> Event.Query.distinct_actor_ids_of_kind(actor_kind)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      ids = Enum.uniq(logged_ids ++ List.wrap(opts[:ensure]))

      labels =
        %{actor_kind => ids}
        |> resolve_labels(subject.account.id)
        |> Map.get(actor_kind, %{})

      options =
        ids
        |> Enum.map(fn id -> {id, Map.get(labels, id)} end)
        |> Enum.reject(fn {_id, label} -> is_nil(label) end)
        |> Enum.sort_by(fn {_id, label} -> label end)

      {:ok, options}
    end
  end

  @doc """
  Distinct subjects of `target_kind` in the account's audit log — the options
  for the page's on-demand "filter by subject" picker, as `{id, label}` sorted by
  label. Mirrors `list_actor_options/2`. Returns `{:ok, [{id, label}]}` or
  `{:error, :unauthorized}`.
  """
  def list_target_options(target_kind, %Subject{} = subject) when is_binary(target_kind) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_audit_permission()) do
      ids =
        Event.Query.all()
        |> Event.Query.distinct_target_ids_of_kind(target_kind)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      labels =
        %{target_kind => ids}
        |> resolve_labels(subject.account.id)
        |> Map.get(target_kind, %{})

      options =
        ids
        |> Enum.map(fn id -> {id, Map.get(labels, id)} end)
        |> Enum.reject(fn {_id, label} -> is_nil(label) end)
        |> Enum.sort_by(fn {_id, label} -> label end)

      {:ok, options}
    end
  end

  defp filter_by_actor_id(queryable, nil), do: queryable

  defp filter_by_actor_id(queryable, id) when is_binary(id) do
    if Repo.valid_uuid?(id),
      do: Event.Query.by_actor_id(queryable, id),
      else: Event.Query.none(queryable)
  end

  defp filter_by_actor_id(queryable, _id), do: Event.Query.none(queryable)

  defp filter_by_target_id(queryable, nil), do: queryable

  defp filter_by_target_id(queryable, id) when is_binary(id) do
    if Repo.valid_uuid?(id),
      do: Event.Query.by_target_id(queryable, id),
      else: Event.Query.none(queryable)
  end

  defp filter_by_target_id(queryable, _id), do: Event.Query.none(queryable)

  @doc """
  SIEM export — cursor-paginated forward sweep of every event the
  subject can see, sorted ascending by `(occurred_at, id)`. This is the
  deterministic shape SIEMs need: they checkpoint the last `(occurred_at,
  id)` they've ingested and ask for everything strictly after.

  Why a separate function from `list_events/2`:

    * Forward (oldest-first) ordering — SIEMs replay history once then
      poll forward; the LV's reverse order would force them to discover
      new rows by binary-searching the timeline.
    * Hard upper bound on the page size — keeps an aggressive consumer
      from issuing a billion-row scan that would page the audit table
      out of buffer pool.
    * No `%Paginator.Metadata{}` count round-trip — SIEM ingestors don't
      need totals and computing them on every poll kills the index.

  Options:

    * `:since` — `%DateTime{}` lower bound for the first page (inclusive)
    * `:after` — `{%DateTime{}, id}` cursor (strict `>`), takes precedence
      over `:since`
    * `:event_types` — list of event_type strings to include (empty list
      = all types)
    * `:limit` — page size, default #{100}, hard-capped at #{1_000}

  Returns `{:ok, events}` — a plain list of `%Audit.Event{}` rows in
  ascending order. The controller projects to NDJSON; the context just
  hands back rows.
  """
  @default_export_limit 100
  @max_export_limit 1_000

  def list_for_export(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_audit_permission()) do
      types = Keyword.get(opts, :event_types, [])
      limit = clamp_export_limit(Keyword.get(opts, :limit, @default_export_limit))

      events =
        Event.Query.all()
        |> apply_export_cursor(opts)
        |> Event.Query.by_event_types(types)
        |> Event.Query.ordered_for_export()
        |> Event.Query.limit_to(limit)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, events}
    end
  end

  @doc """
  Internal — the export controller calls this after a successful page to
  self-log the export ("watch the watchers"). Emits `audit.exported` ONLY when
  the page returned rows (`count > 0`): a caught-up forward-cursor poll (0 rows)
  writes nothing, so a SIEM polling every ~30s doesn't spam the log with its own
  most-frequent event. Account-scoped + attributed via the subject (the api_key
  for a SIEM export). Called post-authorization (`list_for_export` already gated).
  """
  def record_export(%Subject{} = subject, opts, count) when is_integer(count) and count > 0 do
    record(Events.audit_exported(subject, opts, count))
  end

  def record_export(%Subject{} = _subject, _opts, count) when is_integer(count) do
    {:ok, :not_recorded}
  end

  @doc "Public — the controller uses this to ack-clamp a user-supplied `limit` param."
  def max_export_limit, do: @max_export_limit
  @doc "Public — the controller uses this for the default page size."
  def default_export_limit, do: @default_export_limit

  defp clamp_export_limit(n) when is_integer(n) and n > 0,
    do: min(n, @max_export_limit)

  defp clamp_export_limit(_), do: @default_export_limit

  defp apply_export_cursor(query, opts) do
    case Keyword.get(opts, :after) do
      {%DateTime{} = ts, id} when is_binary(id) ->
        if Repo.valid_uuid?(id),
          do: Event.Query.occurred_strictly_after(query, ts, id),
          else: Event.Query.none(query)

      _ ->
        case Keyword.get(opts, :since) do
          %DateTime{} = ts -> Event.Query.occurred_at_or_after(query, ts)
          _ -> query
        end
    end
  end

  @doc """
  Fetch a single event scoped to the subject's account. Returns
  `{:ok, event} | {:error, :not_found}`.
  """
  def fetch_event_by_id(id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_audit_permission()),
         true <- Repo.valid_uuid?(id) do
      Event.Query.all()
      |> Event.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Event.Query)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Bulk-resolves the labels for every actor + subject referenced by the
  given events. Returns a nested map: `%{kind => %{id => label}}`. The
  ids are trusted (they were stamped on the audit row at write time
  inside an already-authorized parent transaction); we only project
  display labels.

  Both call sites pass an already-account-scoped, single-account event
  list (one page of the audit log, or one event). Label lookups are
  therefore additionally scoped to that account: a mis-stamped id can't
  resolve a name/email belonging to another account (defense-in-depth).
  Correctly-scoped ids are unaffected. Mixed-account input degrades to
  the first account's scope rather than leaking, but isn't a supported
  shape.
  """
  def resolve_references(events) when is_list(events) do
    account_id = events |> Enum.map(& &1.account_id) |> List.first()

    events
    |> Enum.flat_map(fn event ->
      [{event.actor_kind, event.actor_id}, {event.target_kind, event.target_id}]
    end)
    |> Enum.reject(fn {_, id} -> is_nil(id) end)
    |> Enum.uniq()
    |> Enum.group_by(fn {kind, _} -> kind end, fn {_, id} -> id end)
    |> resolve_labels(account_id)
  end

  # Resolve a %{kind => [id]} map to %{kind => %{id => label}}, each kind's
  # lookup scoped to account_id. Shared by resolve_references/1 (event
  # actor/subject refs) and list_actor_options/2 (the actor picker).
  defp resolve_labels(ids_by_kind, account_id) do
    %{
      # Users belong to accounts via memberships, not a column, so they
      # scope through the membership join rather than `by_account_id`.
      "user" =>
        fetch_labels(
          Emisar.Users.User.Query,
          ids_by_kind,
          "user",
          :email,
          &Emisar.Users.User.Query.members_of_account(&1, account_id)
        ),
      "runner" =>
        fetch_labels(
          Emisar.Runners.Runner.Query,
          ids_by_kind,
          "runner",
          :name,
          &Emisar.Runners.Runner.Query.by_account_id(&1, account_id)
        ),
      "api_key" =>
        fetch_labels(
          Emisar.ApiKeys.ApiKey.Query,
          ids_by_kind,
          "api_key",
          :name,
          &Emisar.ApiKeys.ApiKey.Query.by_account_id(&1, account_id)
        ),
      # The HUMAN behind an api_key/MCP actor (its creator), keyed by the SAME
      # key ids, so the audit trail leads with who over the key name.
      "api_key_owner" => fetch_owner_labels(ids_by_kind, account_id),
      "enrollment_key" =>
        fetch_labels(
          Emisar.Runners.EnrollmentKey.Query,
          ids_by_kind,
          "enrollment_key",
          :description,
          &Emisar.Runners.EnrollmentKey.Query.by_account_id(&1, account_id)
        ),
      "action_run" =>
        fetch_labels(
          Emisar.Runs.ActionRun.Query,
          ids_by_kind,
          "action_run",
          :action_id,
          &Emisar.Runs.ActionRun.Query.by_account_id(&1, account_id)
        ),
      "approval_request" =>
        fetch_labels(
          Emisar.Approvals.Request.Query,
          ids_by_kind,
          "approval_request",
          :id,
          &Emisar.Approvals.Request.Query.by_account_id(&1, account_id)
        ),
      "runbook" =>
        fetch_labels(
          Emisar.Runbooks.Runbook.Query,
          ids_by_kind,
          "runbook",
          :title,
          &Emisar.Runbooks.Runbook.Query.by_account_id(&1, account_id)
        )
    }
  end

  defp fetch_labels(query_module, ids_by_kind, kind, field, scope) do
    case Map.get(ids_by_kind, kind, []) do
      [] ->
        %{}

      ids ->
        query_module.all()
        |> scope.()
        |> query_module.select_labels(ids, field)
        |> Repo.all()
        |> Map.new()
    end
  end

  # The owner map keys off the "api_key" actor/target ids (a key IS the actor);
  # the join select projects each key id to its creator's name/email.
  defp fetch_owner_labels(ids_by_kind, account_id) do
    case Map.get(ids_by_kind, "api_key", []) do
      [] ->
        %{}

      ids ->
        Emisar.ApiKeys.ApiKey.Query.all()
        |> Emisar.ApiKeys.ApiKey.Query.by_account_id(account_id)
        |> Emisar.ApiKeys.ApiKey.Query.select_owner_labels(ids)
        |> Repo.all()
        |> Map.new()
    end
  end

  # -- Authorization ----------------------------------------------------

  @doc "True when the subject may view the audit trail (the console nav + section gate)."
  def subject_can_view_audit?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.view_audit_permission())
end
