defmodule Emisar.Audit.Event.Query do
  use Emisar, :query
  alias Emisar.Repo.{Filter, Like}

  # What's deliberately NOT audited (so the default listing stays
  # operator-meaningful): run lifecycle states (pending/sent/running) never leave
  # a row — only terminal outcomes + denials + pending_approval do (see
  # `Runs.@audited_run_statuses`); and `policy.evaluated` was retired in the audit
  # logging diet (every allow/deny/require_approval fact already lives on the run
  # row + its terminal audit event), which is why there's no "hide noise" toggle.
  # `runner.connected`/`runner.disconnected` are kept (postmortem value — "when did
  # db-prod-01 last flap") and now read as ordinary, filterable events.

  # The known set of event_type values, ordered by group. Drives the
  # filter dropdown so operators pick from a list instead of typing an
  # exact machine code from memory.
  @known_event_types [
    {"account.created", "Account created"},
    {"account.updated", "Account updated"},
    {"account.require_mfa_set", "MFA enforcement toggled"},
    {"account.require_sso_set", "SSO enforcement toggled"},
    {"account.max_grant_lifetime_set", "Max grant lifetime set"},
    {"runner.registered", "Runner registered"},
    {"runner.connected", "Runner connected"},
    {"runner.disconnected", "Runner disconnected"},
    {"runner.disabled", "Runner disabled"},
    {"runner.enabled", "Runner enabled"},
    {"runner.deleted", "Runner deleted"},
    {"runner.error", "Runner error"},
    {"auth_key.created", "Auth key created"},
    {"auth_key.revoked", "Auth key revoked"},
    {"auth_key.bound", "Auth key bound to runner"},
    {"api_key.created", "API key created"},
    {"api_key.revoked", "API key revoked"},
    {"api_key.bound", "API key first use"},
    {"api_key.auto_rotated", "API key auto-rotated"},
    {"oauth.consent_granted", "OAuth client authorized"},
    {"pack_trust_baseline_match", "Pack auto-trusted (baseline match)"},
    {"pack_trust_baseline_mismatch", "Pack pinned to baseline (drift)"},
    {"pack_trust_review_required", "Pack pending review"},
    {"pack_trust_drift_detected", "Pack drift detected"},
    {"pack_trust_adopted", "Pack hash trusted"},
    {"pack_trust_rejected", "Pack hash rejected"},
    {"dispatch_blocked_pack_untrusted", "Dispatch blocked (pack untrusted)"},
    {"dispatch_blocked_requires_attestation", "Dispatch blocked (unsigned)"},
    {"user.signed_up", "User signed up"},
    {"user.signed_in", "User signed in"},
    {"user.signed_out", "User signed out"},
    {"session.account_switched", "Account switched"},
    {"user.sign_in_failed", "Sign-in failed"},
    {"user.invited", "User invited"},
    {"user.invitation_accepted", "User accepted invitation"},
    {"user.email_confirmed", "Email confirmed"},
    {"user.email_change_requested", "Email change requested"},
    {"user.email_changed", "Email changed"},
    {"user.profile_updated", "Profile updated"},
    {"user.updated_by_admin", "Profile edited by admin"},
    {"user.magic_link_issued", "Magic link issued"},
    {"user.mfa_enabled", "MFA enabled"},
    {"user.mfa_disabled", "MFA disabled"},
    {"user.mfa_failed", "MFA failed"},
    {"user.mfa_recovery_code_used", "MFA recovery code used"},
    {"user.mfa_recovery_codes_regenerated", "MFA recovery codes regenerated"},
    {"user.session_revoked", "Session revoked"},
    {"user.other_sessions_revoked", "Other sessions revoked"},
    {"user.sessions_revoked", "Sessions revoked by admin"},
    {"membership.role_changed", "Role changed"},
    {"membership.removed", "Member removed"},
    {"membership.suspended", "Member suspended"},
    {"membership.reinstated", "Member reinstated"},
    {"membership.invitation_accepted", "Invitation accepted"},
    {"membership.runner_scopes_changed", "Runner scopes changed"},
    {"policy.updated", "Policy updated"},
    {"runbook.created", "Runbook created"},
    {"runbook.updated", "Runbook updated"},
    {"runbook.published", "Runbook published"},
    {"runbook.dispatched", "Runbook dispatched"},
    {"runbook.step_dispatch_failed", "Runbook step dispatch failed"},
    {"approval.approved", "Approval granted"},
    {"approval.denied", "Approval denied"},
    {"approval.expired", "Approval expired"},
    {"approval.grant_used", "Standing grant used"},
    {"approval.grant_revoked", "Standing grant revoked"},
    {"run.cancel_requested", "Run cancel requested"},
    {"action_run.success", "Run succeeded"},
    {"action_run.failed", "Run failed"},
    {"action_run.error", "Run errored"},
    {"action_run.refused", "Run refused (signature / pack)"},
    {"action_run.cancelled", "Run cancelled"},
    {"action_run.timed_out", "Run timed out"},
    {"action_run.denied", "Run denied by policy"},
    {"action_run.pending_approval", "Run awaiting approval"},
    {"user.provisioned_via_sso", "User provisioned (SSO JIT)"},
    {"user.provisioned_via_scim", "User provisioned (SCIM)"},
    {"user.renamed_via_scim", "User renamed (SCIM)"},
    {"membership.deprovisioned_via_scim", "Member deprovisioned (SCIM)"},
    {"membership.reprovisioned_via_scim", "Member reprovisioned (SCIM)"},
    {"membership.role_synced_via_scim", "Member role synced (SCIM)"},
    {"sso.group_mapping_created", "SSO group mapping created"},
    {"sso.group_mapping_updated", "SSO group mapping updated"},
    {"sso.group_mapping_deleted", "SSO group mapping deleted"},
    {"sso.link_request_approved", "SSO link request approved"},
    {"sso.link_request_dismissed", "SSO link request dismissed"},
    {"audit.exported", "Audit log exported"},
    {"audit.retention_swept", "Audit log pruned (retention)"},
    {"subscription.changed", "Subscription plan changed"}
  ]

  def known_event_type_values, do: @known_event_types

  # An event's OUTCOME from its type suffix: a failure (`:danger`), a warn-class
  # denial/removal (`:warn`), or routine (`:neutral`). The audit list/detail
  # dots color by this AND the "Outcome" filter narrows by it, so the two can
  # never disagree — one source, read by both (the web reads it, never copies it).
  @danger_suffixes ~w[_failed .failed .error .timed_out]
  @warn_suffixes ~w[.denied .refused .revoked _revoked .disabled .deleted .removed .suspended .expired .cancelled]

  def outcome(event_type) when is_binary(event_type) do
    cond do
      String.ends_with?(event_type, @danger_suffixes) -> :danger
      String.ends_with?(event_type, @warn_suffixes) -> :warn
      true -> :neutral
    end
  end

  def outcome(_), do: :neutral

  # Same set, grouped by the leading domain so a 34-item dropdown
  # becomes 7 small groups operators can scan instead of reading top
  # to bottom. The Filter UI renders these as <optgroup>s.
  @grouped_event_types [
    {"Account",
     [
       {"account.created", "Created"},
       {"account.updated", "Updated"},
       {"account.require_mfa_set", "MFA enforcement toggled"},
       {"account.require_sso_set", "SSO enforcement toggled"},
       {"account.max_grant_lifetime_set", "Max grant lifetime set"}
     ]},
    {"Runner",
     [
       {"runner.registered", "Registered"},
       {"runner.connected", "Connected"},
       {"runner.disconnected", "Disconnected"},
       {"runner.disabled", "Disabled"},
       {"runner.enabled", "Enabled"},
       {"runner.deleted", "Deleted"},
       {"runner.error", "Error"},
       {"dispatch_blocked_requires_attestation", "Dispatch blocked (unsigned)"}
     ]},
    {"Pack trust",
     [
       {"pack_trust_baseline_match", "Auto-trusted (baseline)"},
       {"pack_trust_baseline_mismatch", "Pinned to baseline (drift)"},
       {"pack_trust_review_required", "Pending review"},
       {"pack_trust_drift_detected", "Drift detected"},
       {"pack_trust_adopted", "Hash trusted"},
       {"pack_trust_rejected", "Hash rejected"},
       {"dispatch_blocked_pack_untrusted", "Dispatch blocked"}
     ]},
    {"Auth key",
     [
       {"auth_key.created", "Created"},
       {"auth_key.revoked", "Revoked"},
       {"auth_key.bound", "Bound to runner"}
     ]},
    {"API key",
     [
       {"api_key.created", "Created"},
       {"api_key.revoked", "Revoked"},
       {"api_key.bound", "First use"},
       {"api_key.auto_rotated", "Auto-rotated"},
       {"oauth.consent_granted", "OAuth client authorized"}
     ]},
    {"Sign-in",
     [
       {"user.signed_up", "Signed up"},
       {"user.signed_in", "Signed in"},
       {"user.signed_out", "Signed out"},
       {"session.account_switched", "Switched account"},
       {"user.sign_in_failed", "Sign-in failed"},
       {"user.magic_link_issued", "Magic link issued"},
       {"user.email_confirmed", "Email confirmed"}
     ]},
    {"User security",
     [
       {"user.email_change_requested", "Email change requested"},
       {"user.email_changed", "Email changed"},
       {"user.profile_updated", "Profile updated"},
       {"user.updated_by_admin", "Profile edited by admin"},
       {"user.mfa_enabled", "MFA enabled"},
       {"user.mfa_disabled", "MFA disabled"},
       {"user.mfa_failed", "MFA failed"},
       {"user.mfa_recovery_code_used", "MFA recovery code used"},
       {"user.mfa_recovery_codes_regenerated", "MFA recovery codes regenerated"},
       {"user.session_revoked", "Session revoked"},
       {"user.other_sessions_revoked", "Other sessions revoked"},
       {"user.sessions_revoked", "Sessions revoked by admin"}
     ]},
    {"Team",
     [
       {"user.invited", "Invited"},
       {"user.invitation_accepted", "Invitation accepted"},
       {"membership.invitation_accepted", "Invitation accepted (existing user)"},
       {"membership.role_changed", "Role changed"},
       {"membership.removed", "Member removed"},
       {"membership.suspended", "Member suspended"},
       {"membership.reinstated", "Member reinstated"},
       {"membership.runner_scopes_changed", "Runner scopes changed"}
     ]},
    {"Policy",
     [
       {"policy.updated", "Updated"}
     ]},
    {"Runbook",
     [
       {"runbook.created", "Created"},
       {"runbook.updated", "Updated (new version)"},
       {"runbook.published", "Published"},
       {"runbook.dispatched", "Dispatched"},
       {"runbook.step_dispatch_failed", "Step dispatch failed"}
     ]},
    {"Approval",
     [
       {"approval.approved", "Granted"},
       {"approval.denied", "Denied"},
       {"approval.expired", "Expired"},
       {"approval.grant_used", "Standing grant used"},
       {"approval.grant_revoked", "Standing grant revoked"}
     ]},
    {"Run",
     [
       {"run.cancel_requested", "Cancel requested"},
       {"action_run.success", "Succeeded"},
       {"action_run.failed", "Failed"},
       {"action_run.error", "Errored"},
       {"action_run.refused", "Refused (signature / pack)"},
       {"action_run.cancelled", "Cancelled"},
       {"action_run.timed_out", "Timed out"},
       {"action_run.denied", "Denied by policy"},
       {"action_run.pending_approval", "Awaiting approval"}
     ]},
    {"SSO / Directory",
     [
       {"user.provisioned_via_sso", "User provisioned (SSO)"},
       {"user.provisioned_via_scim", "User provisioned (SCIM)"},
       {"user.renamed_via_scim", "User renamed (SCIM)"},
       {"membership.deprovisioned_via_scim", "Member deprovisioned"},
       {"membership.reprovisioned_via_scim", "Member reprovisioned"},
       {"membership.role_synced_via_scim", "Role synced"},
       {"sso.group_mapping_created", "Group mapping created"},
       {"sso.group_mapping_updated", "Group mapping updated"},
       {"sso.group_mapping_deleted", "Group mapping deleted"},
       {"sso.link_request_approved", "Link request approved"},
       {"sso.link_request_dismissed", "Link request dismissed"}
     ]},
    {"Audit",
     [
       {"audit.exported", "Exported"},
       {"audit.retention_swept", "Pruned (retention)"}
     ]},
    {"Billing",
     [
       {"subscription.changed", "Plan changed"}
     ]}
  ]

  def grouped_event_type_values, do: @grouped_event_types

  # Groups that log too few events to be worth listing per-type — the Type
  # dropdown collapses them to a single "<Group> — all events" line instead of an
  # optgroup + sub-events (an operator would only ever want the whole class).
  @collapsed_type_groups ["Account", "Policy", "Billing"]

  @doc """
  The Type filter's grouped options. A rich group is an `<optgroup>` with a
  leading, selectable "All <group> events" entry (a `group:<label>` sentinel) plus
  its sub-events. A sparse group (`@collapsed_type_groups`) collapses to a single
  flat "<Group> — all events" line — no sub-events. `expand_event_type_groups/1`
  resolves the sentinel back to the group's types at query time.
  """
  def event_type_filter_options do
    Enum.map(@grouped_event_types, fn {label, options} ->
      if label in @collapsed_type_groups do
        {nil, [{"group:" <> label, label <> " — all events"}]}
      else
        {label, [{"group:" <> label, "All " <> label <> " events"} | options]}
      end
    end)
  end

  # The full legal set for the Type filter — every specific event type plus
  # every `group:<label>` sentinel — used for VALIDATION (the collapsed dropdown
  # hides sparse groups' sub-types, but a specific type is still a legal filter
  # value from a programmatic caller / the outcome filter's expansion).
  def event_type_valid_values do
    sentinels = for {label, _} <- @grouped_event_types, do: {"group:" <> label, label}

    types =
      for {_label, options} <- @grouped_event_types, {value, label} <- options, do: {value, label}

    sentinels ++ types
  end

  # Resolve a Type-filter selection: a `group:<label>` sentinel expands to every
  # event type in that group; a plain type passes through. An unknown sentinel
  # drops to no types — an empty `in` matches nothing, a safe (not crashing) result.
  defp expand_event_type_groups(types) do
    Enum.flat_map(types, fn
      "group:" <> label ->
        case List.keyfind(@grouped_event_types, label, 0) do
          {_, options} -> Enum.map(options, &elem(&1, 0))
          nil -> []
        end

      type ->
        [type]
    end)
  end

  def all,
    do: from(events in Emisar.Audit.Event, as: :events)

  def by_id(queryable, id),
    do: where(queryable, [events: e], e.id == ^id)

  def by_account_id(queryable, account_id),
    do: where(queryable, [events: e], e.account_id == ^account_id)

  def by_event_type(queryable, type),
    do: where(queryable, [events: e], e.event_type == ^type)

  def by_actor_kind(queryable, kind),
    do: where(queryable, [events: e], e.actor_kind == ^kind)

  def by_subject_kind(queryable, kind),
    do: where(queryable, [events: e], e.subject_kind == ^kind)

  @doc """
  Distinct `actor_id`s for actors of `kind` in the scoped events — the id set
  the context resolves to labels for the audit page's on-demand "filter by
  actor" picker.
  """
  def distinct_actor_ids_of_kind(queryable \\ all(), kind) do
    queryable
    |> where([events: e], e.actor_kind == ^kind and not is_nil(e.actor_id))
    |> select([events: e], e.actor_id)
    |> distinct(true)
  end

  @doc """
  The `%Filter{}` for the dynamic actor picker, given its loaded `{id, label}`
  options. The fun lives here (not the LiveView) so the Ecto.Query stays in the
  query module (IL-1).
  """
  def actor_filter(options) do
    %Filter{
      name: :actor_id,
      title: "Actor",
      type: {:list, :string},
      span: :full,
      values: options,
      fun: fn queryable, ids -> {queryable, dynamic([events: e], e.actor_id in ^ids)} end
    }
  end

  def by_subject_id(queryable, id),
    do: where(queryable, [events: e], e.subject_id == ^id)

  def by_actor_id(queryable, id),
    do: where(queryable, [events: e], e.actor_id == ^id)

  @doc "Distinct `subject_id`s of `kind` — options for the on-demand subject picker."
  def distinct_subject_ids_of_kind(queryable \\ all(), kind) do
    queryable
    |> where([events: e], e.subject_kind == ^kind and not is_nil(e.subject_id))
    |> select([events: e], e.subject_id)
    |> distinct(true)
  end

  @doc """
  The `%Filter{}` for the dynamic subject picker, mirroring `actor_filter/1` —
  given its loaded `{id, label}` options. Fun lives here to keep the query in
  the query module (IL-1).
  """
  def subject_filter(options) do
    %Filter{
      name: :subject_id,
      title: "Subject",
      type: {:list, :string},
      span: :full,
      values: options,
      fun: fn queryable, ids -> {queryable, dynamic([events: e], e.subject_id in ^ids)} end
    }
  end

  # The audit page's From/To window goes through the inclusive `:from`/`:to`
  # filters above.
  def occurred_before(queryable, ts),
    do: where(queryable, [events: e], e.occurred_at < ^ts)

  # Retention: a row is prunable once its stamped `retain_until` has passed. (A
  # null `retain_until` — only pre-migration edge rows — never matches, so it's
  # never pruned; safe.)
  def retention_expired(queryable, %DateTime{} = now),
    do: where(queryable, [events: e], e.retain_until < ^now)

  # The retention sweep deletes by id in bounded batches (not one long-locking
  # DELETE): grab ≤ `limit` prunable ids, then delete that set. The `cutoff` the
  # shared worker derives from the CURRENT plan is IGNORED here — per-row
  # `retain_until` (stamped at write time) is the horizon, so a later downgrade
  # can't retroactively wipe rows written under a larger window.
  def prunable_ids(account_id, %DateTime{} = _cutoff, limit) when is_integer(limit) do
    all()
    |> by_account_id(account_id)
    |> retention_expired(DateTime.utc_now())
    |> limit(^limit)
    |> select([events: e], e.id)
  end

  def by_ids(queryable \\ all(), ids) when is_list(ids),
    do: where(queryable, [events: e], e.id in ^ids)

  def ordered_by_recent(queryable \\ all()),
    do: order_by(queryable, [events: e], desc: e.occurred_at)

  # Stable forward order for SIEM export — `(occurred_at, id)` ascending
  # so consumers can poll with a cursor without ever skipping or
  # re-reading rows. UUID v7 ids are time-sortable, which keeps the
  # tie-break identical to the time order for same-microsecond inserts.
  def ordered_for_export(queryable \\ all()),
    do: order_by(queryable, [events: e], asc: e.occurred_at, asc: e.id)

  # Cursor for the export endpoint — accepts the (occurred_at, id) of
  # the last row the consumer has already received and returns rows
  # STRICTLY AFTER that point. Composite-keyset semantics: skip exact
  # ties on the timestamp by also comparing id.
  def occurred_strictly_after(queryable, %DateTime{} = ts, id) when is_binary(id) do
    where(
      queryable,
      [events: e],
      e.occurred_at > ^ts or (e.occurred_at == ^ts and e.id > ^id)
    )
  end

  # Variant for the first page — no id tie-break, just the time bound.
  def occurred_at_or_after(queryable, %DateTime{} = ts),
    do: where(queryable, [events: e], e.occurred_at >= ^ts)

  # IN-list filter for the export `event_type[]` param.
  def by_event_types(queryable, types) when is_list(types) and types != [],
    do: where(queryable, [events: e], e.event_type in ^types)

  def by_event_types(queryable, _), do: queryable

  # Hard-cap; the controller validates the user-supplied limit against
  # @max_export_limit and passes it through, so this stays a one-liner.
  def limit_to(queryable, n) when is_integer(n) and n > 0,
    do: limit(queryable, ^n)

  # -- Pagination / filters --------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:events, :desc, :occurred_at}, {:events, :asc, :id}]

  @impl Emisar.Repo.Query
  def filters,
    do: [
      # `span` lays the filters out as a stacked panel (LiveTable's two-column
      # grid): a Date row (From/To), a Type/Outcome row, then Request ID,
      # Sign-in method, Actor type, and Subject each on their own line. Request
      # ID + Sign-in method are CONDITIONAL — the audit LiveView drops them for
      # event types that never carry a request context / a sign-in (see
      # applicable_filters/2), so they show only when they can actually match.
      # Inclusive date bounds (a "From 10:00" pick includes 10:00:00).
      %Filter{
        name: :from,
        title: "From (UTC)",
        type: :datetime,
        span: :half,
        fun: fn queryable, ts -> {queryable, dynamic([events: e], e.occurred_at >= ^ts)} end
      },
      %Filter{
        name: :to,
        title: "To (UTC)",
        type: :datetime,
        span: :half,
        fun: fn queryable, ts -> {queryable, dynamic([events: e], e.occurred_at <= ^ts)} end
      },
      %Filter{
        name: :event_type,
        title: "Type",
        type: {:list, :string},
        span: :half,
        values: event_type_filter_options(),
        valid_values: event_type_valid_values(),
        fun: fn queryable, types ->
          {queryable, dynamic([events: e], e.event_type in ^expand_event_type_groups(types))}
        end
      },
      %Filter{
        name: :outcome,
        title: "Outcome",
        type: {:list, :string},
        span: :half,
        values: [{"danger", "Failures & errors"}, {"warn", "Denials & removals"}],
        fun: fn queryable, outcomes ->
          types = event_types_for_outcomes(outcomes)
          {queryable, dynamic([events: e], e.event_type in ^types)}
        end
      },
      # Request-id trace: paste the leading part of a request_id to pull every
      # event tied to it. Anchored LIKE keeps the account/request_id prefix index
      # usable; wildcards are escaped to match literally. Conditional — only
      # request-scoped event types carry a request_id.
      %Filter{
        name: :request_id,
        title: "Request ID",
        type: :string,
        span: :full,
        fun: fn queryable, term ->
          {queryable, dynamic([events: e], like(e.request_id, ^Like.prefix(term)))}
        end
      },
      # Sign-in method (provenance). Lets a security buyer answer "show me every
      # action taken via SSO last week" — `auth_method` is stamped only on events
      # a user session produces, so it's conditional on a sign-in / user-security
      # Type being selected.
      %Filter{
        name: :auth_method,
        title: "Sign-in method",
        type: {:list, :string},
        span: :full,
        values: [
          {"magic_link", "Magic link"},
          {"sso", "SSO"}
        ],
        fun: fn queryable, methods ->
          {queryable, dynamic([events: e], e.auth_method in ^methods)}
        end
      },
      %Filter{
        name: :actor_kind,
        title: "Actor type",
        type: {:list, :string},
        span: :full,
        values: [
          {"user", "User"},
          {"api_key", "API key"},
          {"runner", "Runner"},
          {"runbook", "Runbook"},
          {"scheduler", "Scheduler"},
          {"system", "System"}
        ],
        fun: fn queryable, kinds -> {queryable, dynamic([events: e], e.actor_kind in ^kinds)} end
      },
      %Filter{
        name: :subject_kind,
        title: "Subject",
        type: {:list, :string},
        span: :full,
        values: [
          {"user", "User"},
          {"account", "Account"},
          {"runner", "Runner"},
          {"api_key", "API key"},
          {"auth_key", "Auth key"},
          {"action_run", "Action run"},
          {"approval_request", "Approval"},
          {"approval_grant", "Standing grant"},
          {"runbook", "Runbook"},
          {"policy", "Policy"}
        ],
        fun: fn queryable, kinds ->
          {queryable, dynamic([events: e], e.subject_kind in ^kinds)}
        end
      }
    ]

  # The conditional filters (%Filter{} names) that a Type selection supports.
  # Request ID applies unless every selected group is a system/engine origin
  # with no request context; Sign-in method applies only to user-session
  # groups. No Type selected → neither (they'd never match across all types),
  # so the audit LiveView hides them until a relevant Type narrows the log.
  # Request ID rides any request-scoped event; Sign-in method is stamped on any
  # event a USER SESSION produces (not just sign-ins — a policy edit or team
  # change made in a session carries it too), so both apply broadly and are
  # defined by the groups that DON'T carry them: system/engine origins have no
  # request context, and API-key / system actors never sign in.
  @conditional_filter_names [:request_id, :auth_method]
  @no_request_id_groups ["Runner", "Pack trust", "Run", "Billing"]
  @no_auth_method_groups ["Runner", "Pack trust", "Run", "Billing", "API key"]

  @doc """
  Drops the conditional filters (Request ID, Sign-in method) that can't match
  the selected event `Type`, so the audit filter panel only shows filters that
  do something. `type_param` is the raw `event_type` filter value (a list, a
  string, or nil). With no Type selected, both conditional filters are dropped.
  """
  def applicable_filters(filters, type_param) do
    applicable = conditional_filters_for_types(List.wrap(type_param))
    Enum.reject(filters, &(&1.name in @conditional_filter_names and &1.name not in applicable))
  end

  defp conditional_filters_for_types([]), do: []

  defp conditional_filters_for_types(types) do
    groups = types |> Enum.flat_map(&groups_of_type/1) |> Enum.uniq()
    request = if Enum.all?(groups, &(&1 in @no_request_id_groups)), do: [], else: [:request_id]
    auth = if Enum.all?(groups, &(&1 in @no_auth_method_groups)), do: [], else: [:auth_method]
    request ++ auth
  end

  # The group label(s) a Type selection belongs to: a `group:<label>` sentinel
  # names its group directly; a specific event type is looked up in the taxonomy.
  defp groups_of_type("group:" <> label), do: [label]

  defp groups_of_type(type) do
    for {label, options} <- @grouped_event_types,
        Enum.any?(options, fn {value, _} -> value == type end),
        do: label
  end

  # The known event types whose suffix outcome (outcome/1) is one of `outcomes`
  # — the "Outcome" filter resolves to these, so a danger/warn pick narrows to
  # exactly the rows the audit dots color rose/amber.
  defp event_types_for_outcomes(outcomes) do
    for {type, _label} <- @known_event_types, Atom.to_string(outcome(type)) in outcomes, do: type
  end
end
