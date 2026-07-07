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
    {"enrollment_key.created", "Auth key created"},
    {"enrollment_key.revoked", "Auth key revoked"},
    {"enrollment_key.bound", "Auth key bound to runner"},
    {"api_key.created", "API key created"},
    {"api_key.revoked", "API key revoked"},
    {"api_key.bound", "API key first use"},
    {"api_key.auto_rotated", "API key auto-rotated"},
    {"api_key.retired_by_rotation", "API key retired by rotation"},
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
  # denial/removal (`:warn`), a pass verdict (`:pass` — the gate saying YES: a
  # run succeeding, an approval landing, a grant or consent letting something
  # through), or routine (`:neutral`). The audit list/detail dots color by this
  # AND the "Severity" filter narrows by it, so the two can never disagree —
  # one source, read by both (the web reads it, never copies it). Lifecycle
  # positives (connected, enabled, accepted, confirmed) stay :neutral on
  # purpose: green marks verdicts, not activity, or it becomes wallpaper.
  @danger_suffixes ~w[_failed .failed .error .timed_out]
  @warn_suffixes ~w[.denied .refused .revoked _revoked .disabled .deleted .removed .suspended .expired .cancelled]
  @pass_suffixes ~w[.success .approved _approved .grant_used .consent_granted]

  def outcome(event_type) when is_binary(event_type) do
    cond do
      String.ends_with?(event_type, @danger_suffixes) -> :danger
      String.ends_with?(event_type, @warn_suffixes) -> :warn
      String.ends_with?(event_type, @pass_suffixes) -> :pass
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
       {"enrollment_key.created", "Created"},
       {"enrollment_key.revoked", "Revoked"},
       {"enrollment_key.bound", "Bound to runner"}
     ]},
    {"API key",
     [
       {"api_key.created", "Created"},
       {"api_key.revoked", "Revoked"},
       {"api_key.bound", "First use"},
       {"api_key.auto_rotated", "Auto-rotated"},
       {"api_key.retired_by_rotation", "Retired by rotation"},
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

  @doc """
  The Type filter's grouped options, uniform across every group: the CATEGORY
  itself is the selectable header — a `group:<label>` sentinel rendered as
  "<Group> — all events" — followed by its per-event entries.
  `expand_event_type_groups/1` resolves the sentinel back to the group's types
  at query time. Rendered by the searchable filter combobox, never a native
  `<select>` (whose optgroup labels can't be picked — the reason the old
  duplicate "All <group> events" child rows existed).
  """
  def event_type_filter_options do
    Enum.map(@grouped_event_types, fn {label, options} ->
      described =
        for {value, option_label} <- options,
            do: {value, option_label, event_type_description(value)}

      {label,
       [
         {"group:" <> label, label <> " — all events", event_type_description("group:" <> label)}
         | described
       ]}
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

  def by_target_kind(queryable, kind),
    do: where(queryable, [events: e], e.target_kind == ^kind)

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
      # Half-width so it pairs in the cell beside the Actor-kind picker (a
      # :row_start) it's revealed by, not stacked full-width below it.
      span: :half,
      values: options,
      fun: fn queryable, ids -> {queryable, dynamic([events: e], e.actor_id in ^ids)} end
    }
  end

  def by_target_id(queryable, id),
    do: where(queryable, [events: e], e.target_id == ^id)

  def by_actor_id(queryable, id),
    do: where(queryable, [events: e], e.actor_id == ^id)

  @doc "Distinct `target_id`s of `kind` — options for the on-demand subject picker."
  def distinct_target_ids_of_kind(queryable \\ all(), kind) do
    queryable
    |> where([events: e], e.target_kind == ^kind and not is_nil(e.target_id))
    |> select([events: e], e.target_id)
    |> distinct(true)
  end

  @doc """
  The `%Filter{}` for the dynamic subject picker, mirroring `actor_filter/1` —
  given its loaded `{id, label}` options. Fun lives here to keep the query in
  the query module (IL-1).
  """
  def target_filter(options) do
    %Filter{
      name: :target_id,
      title: "Target",
      type: {:list, :string},
      # Half-width — pairs beside the Subject-kind picker that reveals it.
      span: :half,
      values: options,
      fun: fn queryable, ids -> {queryable, dynamic([events: e], e.target_id in ^ids)} end
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
  # DELETE): grab ≤ `limit` prunable ids, then delete that set. Per-row
  # `retain_until` (stamped at write time) is the horizon, so a later downgrade
  # can't retroactively wipe rows written under a larger window.
  def prunable_ids(account_id, limit) when is_integer(limit) do
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
        search: true,
        values: event_type_filter_options(),
        valid_values: event_type_valid_values(),
        fun: fn queryable, types ->
          {queryable, dynamic([events: e], e.event_type in ^expand_event_type_groups(types))}
        end
      },
      %Filter{
        name: :outcome,
        title: "Severity",
        type: {:list, :string},
        span: :half,
        values: [
          {"danger", "Failures & errors"},
          {"warn", "Denials & removals"},
          {"pass", "Successes & approvals"}
        ],
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
        span: :half,
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
        span: :half,
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
        # :row_start — begins its row so the revealed Actor value picker pairs
        # in the cell beside it (see actor_filter/1).
        span: :row_start,
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
        name: :target_kind,
        title: "Target type",
        type: {:list, :string},
        # :row_start — mirrors Actor type; the revealed Subject value picker pairs
        # in the cell beside it.
        span: :row_start,
        values: [
          {"user", "User"},
          {"account", "Account"},
          {"runner", "Runner"},
          {"api_key", "API key"},
          {"enrollment_key", "Auth key"},
          {"approval_request", "Approval"},
          {"approval_grant", "Standing grant"},
          {"runbook", "Runbook"},
          {"policy", "Policy"}
        ],
        fun: fn queryable, kinds ->
          {queryable, dynamic([events: e], e.target_kind in ^kinds)}
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
  # Per-type metadata:
  # {carries request_id?, carries auth_method?, targets other than actor?, description}.
  # request_id/auth_method are PROVENANCE columns riding the %Subject{} — a
  # signed-in user's action carries both; an MCP/API-key request carries only
  # request_id (keys don't "sign in"); engine/socket/sweeper/pre-auth events
  # carry neither (a sign-in's method lives in its PAYLOAD, not the column).
  # The description feeds the Type picker's hover pane — one line on when the
  # event is written.
  @event_type_meta %{
    "account.created" =>
      {false, false, true, "A workspace was created (at sign-up, before any session exists)."},
    "account.updated" => {true, true, true, "An admin changed the workspace's name or slug."},
    "account.require_mfa_set" =>
      {true, true, true, "An admin toggled the workspace-wide two-factor requirement."},
    "account.require_sso_set" =>
      {true, true, true, "An admin toggled the workspace-wide single sign-on requirement."},
    "account.max_grant_lifetime_set" =>
      {true, true, true, "An admin capped how long a standing approval grant may live."},
    "runner.registered" =>
      {true, false, false,
       "A runner enrolled with the control plane (its first HTTP registration)."},
    "runner.connected" =>
      {false, false, false, "A runner's live socket came up — it can now receive actions."},
    "runner.disconnected" =>
      {false, false, false, "A runner's live socket dropped (shutdown, network, or restart)."},
    "runner.disabled" =>
      {true, true, true, "An operator disabled a runner — dispatches to it are refused."},
    "runner.enabled" =>
      {true, true, true, "An operator re-enabled a previously disabled runner."},
    "runner.deleted" =>
      {true, true, true, "An operator removed a runner from the fleet (audit history is kept)."},
    "runner.error" =>
      {true, false, false, "A runner reported an internal error over its socket."},
    "enrollment_key.created" =>
      {true, true, true, "An operator minted a runner bootstrap/auth key."},
    "enrollment_key.revoked" =>
      {true, true, true,
       "An operator revoked a runner auth key — future registrations with it fail."},
    "enrollment_key.bound" =>
      {true, false, true,
       "A runner presented an auth key for the first time and was bound to it."},
    "api_key.created" => {true, true, true, "An operator minted an LLM-agent or export API key."},
    "api_key.revoked" =>
      {true, true, true, "An operator revoked an API key — its next call gets a 401."},
    "api_key.bound" =>
      {true, false, true,
       "An API key was used for the first time (its client identified itself)."},
    "api_key.auto_rotated" => {true, false, true, "The system rotated an API key automatically."},
    "api_key.retired_by_rotation" =>
      {true, false, true,
       "A rotated key's successor was used for the first time — the key it replaces was revoked automatically."},
    "oauth.consent_granted" =>
      {true, true, true, "A user authorized an OAuth client to act on their behalf."},
    "pack_trust_baseline_match" =>
      {false, false, true,
       "A runner advertised a pack matching the compiled-in baseline — auto-trusted."},
    "pack_trust_baseline_mismatch" =>
      {false, false, true,
       "A runner advertised a pack differing from the baseline — pinned pending review."},
    "pack_trust_review_required" =>
      {false, false, true, "A pack version needs an operator's trust decision before it can run."},
    "pack_trust_drift_detected" =>
      {false, false, true, "A runner's pack contents changed under an already-trusted version."},
    "pack_trust_adopted" =>
      {true, true, true, "An operator trusted a pack hash — runners advertising it may execute."},
    "pack_trust_rejected" =>
      {true, true, true, "An operator rejected a pack hash — dispatches with it are refused."},
    "dispatch_blocked_pack_untrusted" =>
      {true, false, true, "A dispatch was refused because the runner's pack isn't trusted."},
    "dispatch_blocked_requires_attestation" =>
      {true, false, true,
       "A dispatch was refused because the request wasn't signed (attestation required)."},
    "user.signed_up" =>
      {false, false, false, "A new user registered (the method rides the event payload)."},
    "user.signed_in" =>
      {true, false, false,
       "A session was established (the method — magic link / SSO — rides the payload)."},
    "user.signed_out" => {true, false, false, "A user ended their session."},
    "session.account_switched" =>
      {false, false, false,
       "A member switched their active workspace (the tenant-entry receipt)."},
    "user.sign_in_failed" =>
      {true, false, false, "A sign-in attempt failed (wrong or expired code, bad link)."},
    "user.invited" => {true, true, true, "An admin invited a teammate into the workspace."},
    "user.invitation_accepted" =>
      {true, false, false, "An invitee accepted and registered a new user account."},
    "user.email_confirmed" =>
      {true, false, false, "A user proved ownership of their email address."},
    "user.email_change_requested" =>
      {true, true, false, "A user asked to change their sign-in email (confirmation pending)."},
    "user.email_changed" => {true, false, false, "A user's sign-in email change completed."},
    "user.profile_updated" => {true, true, false, "A user edited their own profile."},
    "user.updated_by_admin" => {true, true, true, "An admin edited a teammate's profile."},
    "user.magic_link_issued" =>
      {true, false, false, "A sign-in code/link was requested and emailed (consumed or not)."},
    "user.mfa_enabled" => {true, true, false, "A user enrolled a second factor."},
    "user.mfa_disabled" =>
      {true, true, false, "A user (or admin) removed a second-factor enrollment."},
    "user.mfa_failed" => {true, false, false, "A second-factor challenge failed during sign-in."},
    "user.mfa_recovery_code_used" =>
      {true, false, false, "A one-time recovery code was spent to pass the second factor."},
    "user.mfa_recovery_codes_regenerated" =>
      {true, true, false, "A user regenerated their recovery codes (old ones invalidated)."},
    "user.session_revoked" => {true, true, false, "A user revoked one of their own sessions."},
    "user.other_sessions_revoked" =>
      {true, true, false, "A user revoked every session except the current one."},
    "user.sessions_revoked" => {true, true, true, "An admin revoked a teammate's sessions."},
    "membership.role_changed" => {true, true, true, "An admin changed a member's role."},
    "membership.removed" => {true, true, true, "An admin removed a member from the workspace."},
    "membership.suspended" =>
      {true, true, true, "An admin suspended a member — they can't sign into this workspace."},
    "membership.reinstated" => {true, true, true, "An admin reinstated a suspended member."},
    "membership.invitation_accepted" =>
      {true, false, false, "An existing user accepted an invitation into this workspace."},
    "membership.runner_scopes_changed" =>
      {true, true, true, "An admin changed which runners a member may target."},
    "policy.updated" =>
      {true, true, true, "An admin changed the action policy (tier defaults or overrides)."},
    "runbook.created" => {true, true, true, "An operator created a runbook draft."},
    "runbook.updated" => {true, true, true, "An operator edited a runbook (new version)."},
    "runbook.published" =>
      {true, true, true, "An operator published a runbook version for dispatch."},
    "runbook.dispatched" =>
      {true, true, true, "A runbook run started — its steps dispatch in order."},
    "runbook.step_dispatch_failed" =>
      {false, false, true, "The engine couldn't dispatch a runbook step to its runner."},
    "approval.approved" =>
      {true, true, true, "An approver granted a held action (optionally with a standing grant)."},
    "approval.denied" => {true, true, true, "An approver denied a held action."},
    "approval.expired" =>
      {false, false, true, "A held approval request lapsed without a decision (system sweep)."},
    "approval.grant_used" =>
      {true, false, true, "A standing grant auto-approved a matching action."},
    "approval.grant_revoked" => {true, true, true, "An operator revoked a standing grant."},
    "run.cancel_requested" => {true, true, true, "Someone asked to cancel an in-flight run."},
    "action_run.success" =>
      {true, false, true, "A dispatched action completed successfully on its runner."},
    "action_run.failed" =>
      {true, false, true, "A dispatched action exited non-zero on its runner."},
    "action_run.error" =>
      {true, false, true, "A dispatched action errored before/while executing."},
    "action_run.refused" =>
      {true, false, true, "A runner refused an action (signature or pack mismatch)."},
    "action_run.cancelled" => {true, false, true, "An in-flight action was cancelled."},
    "action_run.timed_out" => {true, false, true, "A dispatched action exceeded its time limit."},
    "action_run.denied" => {true, false, true, "Policy denied an action at dispatch."},
    "action_run.pending_approval" =>
      {true, false, true, "Policy held an action for human approval."},
    "user.provisioned_via_sso" =>
      {true, false, false, "A user was created just-in-time on their first SSO sign-in."},
    "user.provisioned_via_scim" =>
      {true, false, true, "The identity provider provisioned a user over SCIM."},
    "user.renamed_via_scim" =>
      {false, false, true, "The identity provider renamed a user over SCIM."},
    "membership.deprovisioned_via_scim" =>
      {true, false, true,
       "The identity provider deprovisioned a member (suspended, sessions killed)."},
    "membership.reprovisioned_via_scim" =>
      {true, false, true, "The identity provider re-activated a previously deprovisioned member."},
    "membership.role_synced_via_scim" =>
      {true, false, true, "A member's role was recomputed from directory group mappings."},
    "sso.group_mapping_created" =>
      {true, true, true, "An admin mapped a directory group to a workspace role."},
    "sso.group_mapping_updated" =>
      {true, true, true, "An admin changed a directory-group role mapping."},
    "sso.group_mapping_deleted" =>
      {true, true, true, "An admin removed a directory-group role mapping."},
    "sso.link_request_approved" =>
      {true, true, true, "A user approved linking their SSO identity to an existing account."},
    "sso.link_request_dismissed" =>
      {true, true, true, "A user dismissed an SSO identity-link request."},
    "audit.exported" => {true, false, true, "Audit events were exported over the SIEM API."},
    "audit.retention_swept" =>
      {false, false, false, "The retention sweep pruned events past their retain-until date."},
    "subscription.changed" =>
      {false, false, true, "The billing plan changed (via checkout or the billing provider)."}
  }

  @doc "One-line description of when an event type is written — the Type picker's hover pane."
  def event_type_description("group:" <> label), do: "Every #{label} event."

  def event_type_description(type), do: type_meta(type) |> elem(3)

  # PROVENANCE support per type — drives which conditional filters apply. A
  # `group:` sentinel supports a filter when ANY of its types does.
  defp type_supports?(name, "group:" <> label) do
    case List.keyfind(@grouped_event_types, label, 0) do
      {_, options} -> Enum.any?(options, fn {value, _} -> type_supports?(name, value) end)
      nil -> false
    end
  end

  defp type_supports?(:request_id, type), do: type_meta(type) |> elem(0)
  defp type_supports?(:auth_method, type), do: type_meta(type) |> elem(1)
  defp type_supports?(:target_kind, type), do: type_meta(type) |> elem(2)

  defp type_meta(type), do: Map.get(@event_type_meta, type, {false, false, true, ""})

  @conditional_filter_names [:request_id, :auth_method, :target_kind]

  @doc """
  Drops the conditional filters that can't match the selected event `Type`, so
  the audit panel only shows filters that do something. Request ID and Sign-in
  method are niche — hidden until a supporting Type is selected. Target type is
  the inverse: useful on the mixed stream (no Type), hidden only when every
  selected type targets nothing but its own actor (a sign-in, a runner
  connect — "Target type" is meaningless for self-events).
  """
  def applicable_filters(filters, type_param, params \\ %{}) do
    types = List.wrap(type_param)

    Enum.reject(filters, fn filter ->
      cond do
        filter.name not in @conditional_filter_names -> false
        # A conditional facet with a LIVE value stays applicable (and visible)
        # regardless of Type — a trace link (`?request_id=req_…` from a run's
        # "View activity") must actually filter, and an applied-but-hidden
        # facet would be an invisible, unclearable filter.
        param_present?(params, filter.name) -> false
        filter.name == :target_kind -> types != [] and not any_type_supports?(types, :target_kind)
        true -> not (types != [] and any_type_supports?(types, filter.name))
      end
    end)
  end

  defp param_present?(params, name) do
    case Map.get(params, to_string(name)) do
      nil -> false
      "" -> false
      list when is_list(list) -> Enum.any?(list, &(&1 not in [nil, ""]))
      _ -> true
    end
  end

  defp any_type_supports?(types, name), do: Enum.any?(types, &type_supports?(name, &1))

  # The known event types whose suffix outcome (outcome/1) is one of `outcomes`
  # — the "Outcome" filter resolves to these, so a danger/warn pick narrows to
  # exactly the rows the audit dots color rose/amber.
  defp event_types_for_outcomes(outcomes) do
    for {type, _label} <- @known_event_types, Atom.to_string(outcome(type)) in outcomes, do: type
  end
end
