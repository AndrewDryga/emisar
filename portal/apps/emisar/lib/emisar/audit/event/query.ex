defmodule Emisar.Audit.Event.Query do
  use Emisar, :query
  alias Emisar.Repo.Filter

  # Event types the audit log fires automatically as a byproduct of
  # normal traffic — one per dispatch (`policy.evaluated`) or per runner
  # socket reconnect (`runner.connected`/`runner.disconnected`, which
  # fires on every network blip). High-frequency but useful for
  # postmortems; they bury the operator-facing events (auth-key minted,
  # member invited, approval decided) in the default listing, so the
  # "Hide noisy events" filter excludes this set. Run lifecycle states
  # (pending/sent/running) are intentionally NOT audited at all — only
  # terminal outcomes + policy denials leave a row (see
  # `Runs.@audited_run_statuses`).
  @noisy_event_types ~w[
    policy.evaluated
    runner.connected
    runner.disconnected
  ]

  def noisy_event_types, do: @noisy_event_types

  # The known set of event_type values, ordered by group. Drives the
  # filter dropdown so operators pick from a list instead of typing an
  # exact machine code from memory.
  @known_event_types [
    {"account.created", "Account created"},
    {"account.updated", "Account updated"},
    {"account.require_mfa_set", "MFA enforcement toggled"},
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
    {"oauth.consent_granted", "OAuth client authorized"},
    {"pack_trust_baseline_match", "Pack auto-trusted (baseline match)"},
    {"pack_trust_baseline_mismatch", "Pack pinned to baseline (drift)"},
    {"pack_trust_review_required", "Pack pending review"},
    {"pack_trust_drift_detected", "Pack drift detected"},
    {"pack_trust_adopted", "Pack hash trusted"},
    {"pack_trust_rejected", "Pack hash rejected"},
    {"dispatch_blocked_pack_untrusted", "Dispatch blocked (pack untrusted)"},
    {"user.signed_up", "User signed up"},
    {"user.signed_in", "User signed in"},
    {"user.signed_out", "User signed out"},
    {"session.account_switched", "Account switched"},
    {"user.sign_in_failed", "Sign-in failed"},
    {"user.invited", "User invited"},
    {"user.invitation_accepted", "User accepted invitation"},
    {"user.email_confirmed", "Email confirmed"},
    {"user.email_changed", "Email changed"},
    {"user.email_change_failed", "Email change failed"},
    {"user.profile_updated", "Profile updated"},
    {"user.updated_by_admin", "Profile edited by admin"},
    {"user.password_changed", "Password changed"},
    {"user.password_change_failed", "Password change failed"},
    {"user.password_reset_requested", "Password reset requested"},
    {"user.password_reset_completed", "Password reset completed"},
    {"user.password_reset_forced", "Password reset forced"},
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
    {"policy.evaluated", "Policy evaluated"},
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
    {"action_run.pending", "Run queued"},
    {"action_run.sent", "Run sent to runner"},
    {"action_run.running", "Run started"},
    {"action_run.success", "Run succeeded"},
    {"action_run.failed", "Run failed"},
    {"action_run.error", "Run errored"},
    {"action_run.cancelled", "Run cancelled"},
    {"action_run.timed_out", "Run timed out"},
    {"action_run.denied", "Run denied by policy"},
    {"action_run.pending_approval", "Run awaiting approval"}
  ]

  def known_event_type_values, do: @known_event_types

  # An event's OUTCOME from its type suffix: a failure (`:danger`), a warn-class
  # denial/removal (`:warn`), or routine (`:neutral`). The audit list/detail
  # dots color by this AND the "Outcome" filter narrows by it, so the two can
  # never disagree — one source, read by both (the web reads it, never copies it).
  @danger_suffixes ~w[_failed .failed .error .timed_out]
  @warn_suffixes ~w[.denied .revoked _revoked .disabled .deleted .removed .suspended .expired .cancelled]

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
       {"account.require_mfa_set", "MFA enforcement toggled"}
     ]},
    {"Runner",
     [
       {"runner.registered", "Registered"},
       {"runner.connected", "Connected"},
       {"runner.disconnected", "Disconnected"},
       {"runner.disabled", "Disabled"},
       {"runner.enabled", "Enabled"},
       {"runner.deleted", "Deleted"},
       {"runner.error", "Error"}
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
    {"Account security",
     [
       {"user.password_changed", "Password changed"},
       {"user.password_change_failed", "Password change failed"},
       {"user.password_reset_requested", "Password reset requested"},
       {"user.password_reset_completed", "Password reset completed"},
       {"user.password_reset_forced", "Password reset forced"},
       {"user.email_changed", "Email changed"},
       {"user.email_change_failed", "Email change failed"},
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
       {"policy.updated", "Updated"},
       {"policy.evaluated", "Evaluated"}
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
       {"action_run.pending", "Queued"},
       {"action_run.sent", "Sent to runner"},
       {"action_run.running", "Started"},
       {"action_run.success", "Succeeded"},
       {"action_run.failed", "Failed"},
       {"action_run.error", "Errored"},
       {"action_run.cancelled", "Cancelled"},
       {"action_run.timed_out", "Timed out"},
       {"action_run.denied", "Denied by policy"},
       {"action_run.pending_approval", "Awaiting approval"}
     ]}
  ]

  def grouped_event_type_values, do: @grouped_event_types

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
      values: options,
      fun: fn queryable, ids -> {queryable, dynamic([events: e], e.subject_id in ^ids)} end
    }
  end

  # Retention sweep cutoff (delete events strictly older than `ts`). The audit
  # page's From/To window goes through the inclusive `:from`/`:to` filters above.
  def occurred_before(queryable, ts),
    do: where(queryable, [events: e], e.occurred_at < ^ts)

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
      # Request-id trace: paste a request_id to pull every event tied to it.
      # ILIKE so a partial paste still matches; wildcards escaped to match
      # literally. (Type filtering is the `event_type` dropdown below.)
      %Filter{
        name: :request_id,
        title: "Request ID",
        type: :string,
        fun: fn queryable, term ->
          pattern = "%" <> escape_like(term) <> "%"
          {queryable, dynamic([events: e], ilike(e.request_id, ^pattern))}
        end
      },
      # Date range — backed by the same %Filter{} mechanism as the rest, so the
      # bar's clear (×) wipes them too. Inclusive bounds (a "From 10:00" pick
      # includes 10:00:00); the LiveTable datetime input parses the UTC value.
      %Filter{
        name: :from,
        title: "From (UTC)",
        type: :datetime,
        fun: fn queryable, ts -> {queryable, dynamic([events: e], e.occurred_at >= ^ts)} end
      },
      %Filter{
        name: :to,
        title: "To (UTC)",
        type: :datetime,
        fun: fn queryable, ts -> {queryable, dynamic([events: e], e.occurred_at <= ^ts)} end
      },
      %Filter{
        name: :event_type,
        title: "Type",
        type: {:list, :string},
        values: grouped_event_type_values(),
        fun: fn queryable, types -> {queryable, dynamic([events: e], e.event_type in ^types)} end
      },
      %Filter{
        name: :actor_kind,
        title: "Actor type",
        type: {:list, :string},
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
      },
      %Filter{
        name: :outcome,
        title: "Outcome",
        type: {:list, :string},
        values: [{"danger", "Failures & errors"}, {"warn", "Denials & removals"}],
        fun: fn queryable, outcomes ->
          types = event_types_for_outcomes(outcomes)
          {queryable, dynamic([events: e], e.event_type in ^types)}
        end
      },
      %Filter{
        name: :hide_noise,
        title: "Hide noisy events",
        type: :boolean,
        fun: fn queryable, true ->
          {queryable, dynamic([events: e], e.event_type not in ^@noisy_event_types)}
        end
      }
    ]

  # The known event types whose suffix outcome (outcome/1) is one of `outcomes`
  # — the "Outcome" filter resolves to these, so a danger/warn pick narrows to
  # exactly the rows the audit dots color rose/amber.
  defp event_types_for_outcomes(outcomes) do
    for {type, _label} <- @known_event_types, Atom.to_string(outcome(type)) in outcomes, do: type
  end

  # Escape LIKE/ILIKE wildcards so a pasted id matches literally: a request_id
  # like `req_…` carries `_` (a single-char wildcard) and `%`/`\` shouldn't act
  # as patterns either. Backslash first, so the escapes we add aren't re-escaped;
  # Postgres ILIKE uses `\` as the default escape char.
  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
