defmodule Emisar.Audit do
  @moduledoc """
  System-of-record audit log. Append-only; queryable by time, type,
  actor, target. Distinct from `Runs.RunEvent` (progress chunks for
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

  IP, user agent, and request id are the inbound request's context. They
  ride in a `%RequestContext{}` passed via the `:context`
  attr key — from the caller's `%Subject{}` for an authenticated event
  (`Audit.Events` builders pull `subject.context` automatically), or
  explicitly on the pre-auth path. An event with no `:context` (system /
  engine origin) carries no request metadata, by construction.
  """
  use Supervisor
  alias Emisar.{Accounts, Auth, Billing, Repo, RequestContext, Runners, Runs}
  alias Emisar.Audit.{Authorizer, Event, Events}
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
  to join (runner connect/disconnect). Like `log/3`, it does not
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
              runbook_execution_id: run.runbook_execution_id,
              runbook_execution_item_id: run.runbook_execution_item_id,
              runbook_step_id: run.runbook_step_id,
              attempt_number: run.attempt_number,
              pack_ref: run.pack_ref,
              expected_pack_hash: run.expected_pack_hash,
              exit_code: run.exit_code,
              duration_ms: run.duration_ms,
              executed_command: run.executed_command,
              executed_command_truncated: run.executed_command_truncated,
              local_audit_failed: if(run.local_audit_failed, do: true),
              reason: run.reason_text,
              # Self-reported MCP client metadata snapshotted at dispatch, so a
              # terminal event logged long after (from the runner socket) still
              # carries it. Empty → dropped by compact, so non-MCP rows stay lean.
              mcp_client_metadata: mcp_client_metadata(run),
              # Positive per-run signing evidence for a bridge-attested (signed
              # dispatch) run: that it was signed, the CA + leaf key that vouched
              # for it, and the bridge operation id — so a successful run's
              # signature is provable in the audit and cross-referenceable to a
              # SIEM. compact drops all of these on an unsigned run.
              signed: if(signed?(run), do: true),
              signing_ca_id: signing_cert(run, "ca_id"),
              signing_key_id: signing_cert(run, "key_id"),
              operation_id: run.operation_id
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

  # Positive signing evidence for a bridge-attested run's terminal audit event
  # (see `run_event_changeset/1`). `attestation` carries the relayed v4 envelope;
  # its `cert` names the CA and leaf key that authorized the dispatch.
  defp signed?(%Runs.ActionRun{attestation: %{"cert" => %{}}}), do: true
  defp signed?(%Runs.ActionRun{}), do: false

  defp signing_cert(%Runs.ActionRun{attestation: %{"cert" => %{} = cert}}, key), do: cert[key]
  defp signing_cert(%Runs.ActionRun{}, _key), do: nil

  defp actor_kind(%Runs.ActionRun{requested_by_id: id}) when not is_nil(id), do: "user"
  defp actor_kind(%Runs.ActionRun{api_key_id: id}) when not is_nil(id), do: "api_key"
  defp actor_kind(%Runs.ActionRun{source: :runbook}), do: "runbook"
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
    with :ok <- ensure_can_read_audit(subject) do
      # actor_id / target_id ride as opts — the dynamic "by actor" / "by
      # subject" pickers aren't in the static filters/0 list, so they can't go
      # through :filter. Everything else is a LiveTable filter, applied via :filter.
      {actor_id, opts} = Keyword.pop(opts, :actor_id)
      {target_id, opts} = Keyword.pop(opts, :target_id)

      # Events are append-only, so ANY view of them — a date window or outcome
      # chip as much as the unnarrowed trail — can grow past what an exact
      # aggregate should scan. `:auto` counts exactly while the planner says
      # the set is affordable and reports its estimate once it isn't. `put_new`
      # leaves an explicit `count:` alone, so the CSV export's cursor walk
      # keeps its `count: false`.
      opts = Keyword.put_new(opts, :count, :auto)
      scope = audit_scope(subject)

      Event.Query.all()
      |> filter_by_actor_id(actor_id)
      |> filter_by_target_id(target_id)
      |> Event.Query.by_target_access(scope)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Event.Query, opts)
      |> withhold_listed(scope)
    end
  end

  defp withhold_listed({:ok, events, metadata}, scope),
    do: {:ok, withhold_out_of_reach(events, scope), metadata}

  defp withhold_listed({:error, reason}, _scope), do: {:error, reason}

  @doc """
  The retained audit receipts for approval decisions, keyed by request id.
  Requires audit-view permission and returns
  `{:ok, %{request_id => %{final: event_id, decisions: %{actor_id => event_id}}}}`
  or `{:error, :unauthorized}`. Invalid or cross-account request ids contribute
  no entries.
  """
  def approval_event_refs(request_ids, %Subject{} = subject) when is_list(request_ids) do
    with :ok <- ensure_can_read_audit(subject) do
      ids = request_ids |> Enum.filter(&Repo.valid_uuid?/1) |> Enum.uniq() |> Enum.take(100)

      events =
        Event.Query.all()
        |> Event.Query.by_target_kind("approval_request")
        |> Event.Query.by_target_ids(ids)
        |> Event.Query.by_event_types(~w[
          approval.decision_recorded approval.approved approval.denied approval.expired
        ])
        |> Event.Query.ordered_by_recent()
        |> Event.Query.limit_to(2_000)
        |> Event.Query.by_target_access(audit_scope(subject))
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, Enum.reduce(events, %{}, &put_approval_event_ref/2)}
    end
  end

  defp put_approval_event_ref(%Event{event_type: "approval.decision_recorded"} = event, refs) do
    update_in(
      refs,
      [Access.key(event.target_id, empty_approval_refs())],
      &update_in(&1, [:decisions], fn decisions ->
        Map.put_new(decisions, event.actor_id, event.id)
      end)
    )
  end

  defp put_approval_event_ref(%Event{} = event, refs) do
    update_in(
      refs,
      [Access.key(event.target_id, empty_approval_refs())],
      fn
        %{final: nil} = request_refs -> %{request_refs | final: event.id}
        request_refs -> request_refs
      end
    )
  end

  defp empty_approval_refs, do: %{final: nil, decisions: %{}}

  @doc """
  Distinct actors of `actor_kind` that appear in the account's audit log — the
  options for the page's on-demand actor filter, as `{id, label}` sorted by
  label (a bounded lookup, not a paginated list). Labels resolve cross-context
  the same way the table's actor column does; an id whose row is gone (deleted
  since the event, or only resolvable in another account) is dropped. Returns
  `{:ok, [{id, label}]}` or `{:error, :unauthorized}`.

  `opts[:ensure]` forces an actor id into the option set even with zero events
  (a Team "View activity" link for a member who hasn't acted yet), so the picker
  can SELECT it instead of falling back to All. It is a caller-supplied id — the
  audit page takes it straight from the URL — so it buys no reach: the label
  still resolves through the subject's own narrowing, and an id that resolves to
  nothing (another account's, or a runner outside their fleet) is dropped.
  """
  def list_actor_options(actor_kind, %Subject{} = subject, opts \\ [])
      when is_binary(actor_kind) do
    with :ok <- ensure_can_read_audit(subject) do
      scope = audit_scope(subject)

      logged_ids =
        Event.Query.all()
        |> Event.Query.distinct_actor_ids_of_kind(actor_kind)
        |> Event.Query.by_target_access(scope)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      ids = Enum.uniq(logged_ids ++ List.wrap(opts[:ensure]))

      labels =
        %{actor_kind => ids}
        |> resolve_labels(subject.account.id, scope)
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
    with :ok <- ensure_can_read_audit(subject) do
      scope = audit_scope(subject)

      ids =
        Event.Query.all()
        |> Event.Query.distinct_target_ids_of_kind(target_kind)
        |> Event.Query.by_target_access(scope)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      labels =
        %{target_kind => ids}
        |> resolve_labels(subject.account.id, scope)
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

  # Per-user runner + pack scope applies to the audit log the same way it applies
  # to runs, approvals, and the catalog. The receipts can carry command, decision,
  # or trust details, so a target kind must not become a side door to records the
  # member cannot open on their owning page.
  #
  # Resolved ONCE per read and threaded, because the same narrowing decides three
  # things: which rows come back, which display labels resolve, and which identity
  # inside a payload is readable. An unrestricted member never pays for the fleet
  # lookup — every consumer branches on `access.mode` first, so the two lists stay
  # empty and unread for them.
  defp audit_scope(%Subject{} = subject) do
    case Accounts.runner_access_for_subject(subject) do
      %Accounts.RunnerAccess{mode: :all} = access ->
        %{access: access, runner_ids: [], groups: []}

      access ->
        {runner_ids, groups} = Runners.reachable_scope_values(subject.account.id, access)
        %{access: access, runner_ids: runner_ids, groups: groups}
    end
  end

  # What a receipt MENTIONS, as opposed to what it is ABOUT. A grant snapshot
  # names runner groups, runner ids, and pack ids; a retention sweep names the
  # rows it removed. None of that decides whether the reader may open the event,
  # so withholding the row would cost a member the record of their own
  # membership, invitation, and provisioning events — the identity inside it is
  # withheld instead, and the event stays readable.
  #
  # An unrestricted member reads every value; a narrowed one reads the names
  # their own access already reaches, so their OWN grant survives whole while
  # another member's stops naming hosts they cannot see. A sweep's `runners`
  # list is the one value that cannot be re-judged — it names rows the sweep
  # DELETED, so their group is unknowable at read time — and is dropped rather
  # than guessed at; `count` still reports the sweep's real size.
  defp withhold_out_of_reach(events, scope) when is_list(events),
    do: Enum.map(events, &withhold_out_of_reach(&1, scope))

  defp withhold_out_of_reach(%Event{} = event, %{access: %Accounts.RunnerAccess{mode: :all}}),
    do: event

  defp withhold_out_of_reach(%Event{payload: payload} = event, scope) when is_map(payload),
    do: %Event{event | payload: withhold_payload(payload, scope)}

  defp withhold_out_of_reach(%Event{} = event, _scope), do: event

  defp withhold_payload(payload, scope) do
    Enum.reduce(payload, %{}, fn {key, value}, kept ->
      case withhold_entry(key, value, scope) do
        :withhold -> kept
        {:keep, value} -> Map.put(kept, key, value)
      end
    end)
  end

  defp withhold_entry("runners", _swept_names, _scope), do: :withhold

  defp withhold_entry("versions", versions, scope) when is_list(versions),
    do: {:keep, Enum.filter(versions, &pack_ref_in_reach?(&1, scope))}

  defp withhold_entry("runner_id", runner_id, scope) when is_binary(runner_id) do
    if runner_id in scope.runner_ids, do: {:keep, runner_id}, else: :withhold
  end

  defp withhold_entry(_key, value, scope) when is_map(value),
    do: {:keep, withhold_access_snapshot(value, scope)}

  defp withhold_entry(_key, value, _scope), do: {:keep, value}

  # The persisted shape of `Audit.Events`' runner-access snapshot — the one
  # payload value that names hosts and packs wholesale, under `runner_access`,
  # `before`, or `after` depending on the event.
  defp withhold_access_snapshot(
         %{"mode" => _mode, "groups" => groups, "runner_ids" => runner_ids} = snapshot,
         scope
       )
       when is_list(groups) and is_list(runner_ids) do
    snapshot
    |> Map.put("groups", Enum.filter(groups, &(&1 in scope.groups)))
    |> Map.put("runner_ids", Enum.filter(runner_ids, &(&1 in scope.runner_ids)))
    |> withhold_pack_ids(scope)
  end

  defp withhold_access_snapshot(value, _scope), do: value

  defp withhold_pack_ids(%{"pack_ids" => pack_ids} = snapshot, scope) when is_list(pack_ids) do
    kept = Enum.filter(pack_ids, &Accounts.RunnerAccess.pack_in_scope?(&1, scope.access))
    Map.put(snapshot, "pack_ids", kept)
  end

  defp withhold_pack_ids(snapshot, _scope), do: snapshot

  # A swept pack version reads `"<pack_id>@<version>"`, and the pack dimension
  # owns it. A BARE version string names no pack of its own — it belongs to a
  # payload that states its `pack_id` beside the list — so it is left alone
  # rather than read as a pack id that matches nothing.
  defp pack_ref_in_reach?(version_ref, scope) when is_binary(version_ref) do
    case String.split(version_ref, "@", parts: 2) do
      [pack_id, _version] -> Accounts.RunnerAccess.pack_in_scope?(pack_id, scope.access)
      [_version] -> true
    end
  end

  defp pack_ref_in_reach?(_version_ref, _scope), do: false

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
  ascending order, or `{:error, :unauthorized | :audit_export_not_available}`
  (export is the paid surface — see `list_events_for_export/2`). The
  controller projects to NDJSON; the context just hands back rows.
  """
  @default_export_limit 100
  @max_export_limit 1_000

  def list_for_export(%Subject{} = subject, opts \\ []) do
    with :ok <- ensure_can_export_audit(subject) do
      types = Keyword.get(opts, :event_types, [])
      limit = clamp_export_limit(Keyword.get(opts, :limit, @default_export_limit))
      scope = audit_scope(subject)

      events =
        Event.Query.all()
        |> apply_export_cursor(opts)
        |> Event.Query.by_event_types(types)
        |> Event.Query.ordered_for_export()
        |> Event.Query.limit_to(limit)
        |> Event.Query.by_target_access(scope)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, withhold_out_of_reach(events, scope)}
    end
  end

  @doc """
  The CSV-download read — the operator's current filtered view, in the same
  paginated shape as `list_events/2`, but gated on the paid audit-export
  entitlement: the in-console trail stays on every plan, taking the data OUT
  is Team+. Returns `{:ok, [event], %Paginator.Metadata{}}` or
  `{:error, :unauthorized | :audit_export_not_available}`.
  """
  def list_events_for_export(%Subject{} = subject, opts \\ []) do
    with :ok <- ensure_can_export_audit(subject) do
      list_events(subject, opts)
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
    with :ok <- ensure_can_read_audit(subject),
         true <- Repo.valid_uuid?(id) do
      scope = audit_scope(subject)

      Event.Query.all()
      |> Event.Query.by_id(id)
      |> Event.Query.by_target_access(scope)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Event.Query)
      |> withhold_fetched(scope)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp withhold_fetched({:ok, %Event{} = event}, scope),
    do: {:ok, withhold_out_of_reach(event, scope)}

  defp withhold_fetched({:error, reason}, _scope), do: {:error, reason}

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

  The subject's own runner access narrows it further: a name is a label, and a
  label is the thing a restricted member must not learn about a host, group, or
  ruleset outside their reach. Resolution is the single choke point for that —
  the picker's caller-supplied `:ensure` id passes through here too, so it can
  never name something the member could not already see.
  """
  def resolve_references(events, %Subject{} = subject) when is_list(events) do
    account_id = events |> Enum.map(& &1.account_id) |> List.first()

    events
    |> Enum.flat_map(fn event ->
      [{event.actor_kind, event.actor_id}, {event.target_kind, event.target_id}]
    end)
    |> Enum.reject(fn {_, id} -> is_nil(id) end)
    |> Enum.uniq()
    |> Enum.group_by(fn {kind, _} -> kind end, fn {_, id} -> id end)
    |> resolve_labels(account_id, audit_scope(subject))
  end

  # Resolve a %{kind => [id]} map to %{kind => %{id => label}}, each kind's
  # lookup scoped to account_id and to the reader's runner access. Shared by
  # resolve_references/2 (event actor/subject refs) and the option pickers.
  defp resolve_labels(ids_by_kind, account_id, scope) do
    %{
      # Users belong to accounts via memberships, not a column, so they
      # scope through the membership join rather than `by_account_id`.
      "user" =>
        fetch_labels(
          Emisar.Users.User.Query,
          ids_by_kind,
          "user",
          :display_name,
          &Emisar.Users.User.Query.members_of_account(&1, account_id)
        ),
      "runner" =>
        fetch_labels(
          Emisar.Runners.Runner.Query,
          ids_by_kind,
          "runner",
          :name,
          &(&1 |> Emisar.Runners.Runner.Query.by_account_id(account_id) |> in_runner_reach(scope))
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
      "approval_request" => fetch_request_labels(ids_by_kind, account_id),
      "runbook" =>
        fetch_labels(
          Emisar.Runbooks.Runbook.Query,
          ids_by_kind,
          "runbook",
          :title,
          &Emisar.Runbooks.Runbook.Query.by_account_id(&1, account_id)
        ),
      "approval_grant" =>
        fetch_labels(
          Emisar.Approvals.Grant.Query,
          ids_by_kind,
          "approval_grant",
          :action_id,
          &Emisar.Approvals.Grant.Query.by_account_id(&1, account_id)
        ),
      "identity_provider" =>
        fetch_labels(
          Emisar.SSO.IdentityProvider.Query,
          ids_by_kind,
          "identity_provider",
          :name,
          &Emisar.SSO.IdentityProvider.Query.by_account_id(&1, account_id)
        ),
      "pack_version" => fetch_pack_version_labels(ids_by_kind, account_id),
      "policy" => fetch_policy_labels(ids_by_kind, account_id, scope)
    }
  end

  # A runner's NAME is the leak, so the label lookup carries the same narrowing
  # its own console list does: an unrestricted reader resolves every runner in
  # the account, a narrowed one only the fleet they hold, and `none` resolves
  # nothing at all.
  defp in_runner_reach(queryable, %{access: %Accounts.RunnerAccess{mode: :all}}), do: queryable

  defp in_runner_reach(queryable, %{access: %Accounts.RunnerAccess{mode: :none}}),
    do: Emisar.Runners.Runner.Query.none(queryable)

  defp in_runner_reach(queryable, %{access: %Accounts.RunnerAccess{} = access}) do
    Emisar.Runners.Runner.Query.by_scope_values(queryable, access.runner_ids, access.groups)
  end

  defp fetch_pack_version_labels(ids_by_kind, account_id) do
    case Map.get(ids_by_kind, "pack_version", []) do
      [] ->
        %{}

      ids ->
        Emisar.Catalog.PackVersion.Query.all()
        |> Emisar.Catalog.PackVersion.Query.by_account_id(account_id)
        |> Emisar.Catalog.PackVersion.Query.select_audit_labels(ids)
        |> Repo.all()
        |> Map.new(fn {id, pack_id, version} -> {id, "#{pack_id}@#{version}"} end)
    end
  end

  # A request's name is a projection of its frozen context, so it resolves the
  # same way Approvals words it on the queue — never the raw id, which reads as
  # an unresolved ref beside every other kind's human label. A context naming
  # neither a runbook nor an action stays out of the map, so the trail falls
  # back to the id rather than rendering a blank Target.
  defp fetch_request_labels(ids_by_kind, account_id) do
    case Map.get(ids_by_kind, "approval_request", []) do
      [] ->
        %{}

      ids ->
        Emisar.Approvals.Request.Query.all()
        |> Emisar.Approvals.Request.Query.by_account_id(account_id)
        |> Emisar.Approvals.Request.Query.select_audit_labels(ids)
        |> Repo.all()
        |> Enum.reduce(%{}, fn {id, context}, labels ->
          case Emisar.Approvals.request_name(context) do
            nil -> labels
            name -> Map.put(labels, id, name)
          end
        end)
    end
  end

  # A ruleset's label IS its scope — `Runner policy · <uuid>`, `Group policy ·
  # <name>` — so it resolves only for a scope the reader reaches. The account
  # default names no host and always resolves.
  defp fetch_policy_labels(ids_by_kind, account_id, scope) do
    case Map.get(ids_by_kind, "policy", []) do
      [] ->
        %{}

      ids ->
        Emisar.Policies.Policy.Query.all()
        |> Emisar.Policies.Policy.Query.by_account_id(account_id)
        |> in_policy_reach(scope)
        |> Emisar.Policies.Policy.Query.select_audit_labels(ids)
        |> Repo.all()
        |> Map.new(fn
          {id, :account, _scope_value} -> {id, "Default policy"}
          {id, :runner, scope_value} -> {id, "Runner policy · #{scope_value}"}
          {id, :group, scope_value} -> {id, "Group policy · #{scope_value}"}
        end)
    end
  end

  defp in_policy_reach(queryable, %{access: %Accounts.RunnerAccess{mode: :all}}), do: queryable

  defp in_policy_reach(queryable, %{runner_ids: runner_ids, groups: groups}),
    do: Emisar.Policies.Policy.Query.by_scope_reach(queryable, runner_ids, groups)

  defp fetch_labels(query_module, ids_by_kind, kind, field, narrow) do
    case Map.get(ids_by_kind, kind, []) do
      [] ->
        %{}

      ids ->
        query_module.all()
        |> narrow.()
        |> query_module.select_labels(ids, field)
        |> Repo.all()
        |> Map.new()
    end
  end

  # The owner map keys off the "api_key" actor/target ids (a key IS the actor);
  # ApiKeys names each key's minter the way THIS account knows them, so a person
  # whose membership here ended resolves nothing and the trail shows the key name.
  defp fetch_owner_labels(ids_by_kind, account_id) do
    # Mirrors fetch_labels/5: with no ids there is no account to scope to
    # either — an empty event list carries no account_id.
    case Map.get(ids_by_kind, "api_key", []) do
      [] -> %{}
      ids -> Emisar.ApiKeys.owner_labels_for_ids(ids, account_id)
    end
  end

  # -- UI metadata -----------------------------------------------------

  @doc "The known `{event_type, label}` pairs — the audit list's event-type labels."
  def known_event_type_values, do: Event.Query.known_event_type_values()

  @doc """
  The event's outcome class from its type suffix — `:danger | :warn | :pass |
  :neutral`. One source for the audit dots and the Outcome filter.
  """
  def event_outcome(event_type), do: Event.Query.outcome(event_type)

  @doc """
  The review-category `{value, label}` options this subject can narrow BY —
  EMPTY when their readable slice falls in one category, since picking it would
  change nothing they can already see.

  Read off the `:category` facet the panel itself renders, so the quick filters and the
  facet are one list by construction rather than two that agree today.
  """
  def event_category_values(%Subject{} = subject) do
    case Enum.find(event_filters(subject), &(&1.name == :category)) do
      nil -> []
      filter -> filter.values
    end
  end

  @doc """
  The audit facet panel's full `%Repo.Filter{}` list, narrowed to what this
  subject's reads can actually return — see `Event.Query.readable_filters/2`.
  """
  def event_filters(%Subject{} = subject) do
    Event.Query.readable_filters(Event.Query.filters(), Authorizer.readable_event_types(subject))
  end

  @doc """
  The audit facet panel's filters with conditional facets dropped when the
  selected Type can't carry them, on top of the subject's readable narrowing.
  """
  def applicable_event_filters(type_param, params, %Subject{} = subject),
    do: Event.Query.applicable_filters(event_filters(subject), type_param, params)

  @doc "The `%Repo.Filter{}` for the actor picker, given its loaded `{id, label}` options."
  def actor_filter(options), do: Event.Query.actor_filter(options)

  @doc "The `%Repo.Filter{}` for the target picker, given its loaded `{id, label}` options."
  def target_filter(options), do: Event.Query.target_filter(options)

  # -- Authorization ----------------------------------------------------

  @doc """
  True when the subject may reach the audit trail at all — the whole record, or
  the billing slice a billing manager sees (the console nav + section gate).
  """
  def subject_can_view_audit?(%Subject{} = subject) do
    Auth.Authorizer.has_permission?(subject, Authorizer.view_audit_permission()) or
      Auth.Authorizer.has_permission?(subject, Authorizer.view_billing_audit_permission())
  end

  @doc """
  True when the subject reads the audit trail narrowed to billing events — the
  finance seat. The web words the page from it; `Authorizer.for_subject/2` is
  what actually withholds the rows.
  """
  def subject_sees_billing_audit_only?(%Subject{} = subject) do
    subject_can_view_audit?(subject) and
      not Auth.Authorizer.has_permission?(subject, Authorizer.view_audit_permission())
  end

  @doc """
  True when the subject may take the record OUT of the product — the gate behind
  the CSV and SIEM export controls. The plan entitlement is a separate,
  account-level check; `ensure_can_export_audit/1` is authoritative for both.
  """
  def subject_can_export_audit?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.view_audit_permission())

  # Either audit permission opens a read — how MUCH of the trail comes back is
  # `Authorizer.for_subject/2`'s call, not this gate's.
  defp ensure_can_read_audit(%Subject{} = subject) do
    Auth.Authorizer.ensure_has_permissions(
      subject,
      {:one_of, [Authorizer.view_audit_permission(), Authorizer.view_billing_audit_permission()]}
    )
  end

  # Export (the SIEM sweep and the CSV download alike) is the paid surface —
  # the in-console trail stays on every plan. The web's plan checks are
  # courtesy navigation/copy; this gate is authoritative for both export reads.
  # Deliberately the FULL-trail permission: taking the record out of the product
  # is an owner/admin/SIEM act, not part of the finance seat's read.
  defp ensure_can_export_audit(%Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_audit_permission()) do
      if Billing.audit_export_available?(account),
        do: :ok,
        else: {:error, :audit_export_not_available}
    end
  end
end
