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
    {"account.require_mfa_set", "MFA requirement changed"},
    {"account.require_sso_set", "SSO requirement changed"},
    {"account.max_grant_lifetime_set", "Maximum grant lifetime changed"},
    {"account.disabled", "Account disabled"},
    {"account.enabled", "Account enabled"},
    {"account.closed", "Account closed"},
    {"runner.registered", "Runner registered"},
    {"runner.connected", "Runner connected"},
    {"runner.disconnected", "Runner disconnected"},
    {"runner.disabled", "Runner disabled"},
    {"runner.credential_rotation_requested", "Runner key rotation requested"},
    {"runner.credential_rotated", "Runner replacement key used"},
    {"runner.enabled", "Runner enabled"},
    {"runner.deleted", "Runner deleted"},
    {"runner.error", "Runner error"},
    {"runner.version_rejected", "Runner connection blocked: unsupported version"},
    {"runner.retention_swept", "Offline runners cleaned up"},
    {"enrollment_key.created", "Enrollment key created"},
    {"enrollment_key.revoked", "Enrollment key revoked"},
    {"enrollment_key.bound", "Enrollment key used for registration"},
    {"api_key.created", "API key created"},
    {"api_key.rotation_requested", "API key rotation requested"},
    {"api_key.revoked", "API key revoked"},
    {"api_key.bound", "API key used for the first time"},
    {"api_key.auto_rotated", "API key rotation started"},
    {"api_key.retired_by_rotation", "Previous API key revoked after rotation"},
    {"api_key.device_grant_approved", "Agent connection approved"},
    {"api_key.device_grant_denied", "Agent connection denied"},
    {"oauth.consent_granted", "OAuth client authorized"},
    {"oauth.refresh_token_reused", "OAuth refresh token reused"},
    {"pack_trust_baseline_match", "Pack automatically trusted"},
    {"pack_trust_baseline_mismatch", "Pack differs from published version"},
    {"pack_trust_baseline_reconciled", "Pack trusted after catalog update"},
    {"pack_trust_review_required", "Pack needs review"},
    {"pack_trust_drift_detected", "New pack contents reported"},
    {"pack_trust_adopted", "Pack hash trusted"},
    {"pack_trust_rejected", "Pack hash rejected"},
    {"pack_trust_revoked", "Pack trust revoked"},
    {"pack_retirement_overridden", "Pack retirement restriction overridden"},
    {"pack_version_deleted", "Pack version deleted"},
    {"pack_deleted", "Pack deleted"},
    {"pack_retention_swept", "Unused pack versions cleaned up"},
    {"pack_retirement_swept", "Retired pack versions cleaned up"},
    {"dispatch_blocked_pack_untrusted", "Action blocked: pack not trusted"},
    {"dispatch_blocked_pack_retired", "Action blocked: pack version retired"},
    {"dispatch_blocked_requires_attestation", "Action blocked: signature required"},
    {"dispatch_blocked_target_unavailable", "Action request rejected"},
    {"user.signed_up", "User signed up"},
    {"user.signed_in", "User signed in"},
    {"user.signed_out", "User signed out"},
    {"session.account_switched", "User switched to this account"},
    {"user.sign_in_failed", "Sign-in failed"},
    {"user.invited", "User invited"},
    {"user.invitation_accepted", "Invitation accepted"},
    {"user.email_confirmed", "Email confirmed"},
    {"user.email_change_requested", "Email change requested"},
    {"user.email_change_code_failed", "Email change confirmation failed"},
    {"user.oidc_identity_step_up_requested", "Sign-in method confirmation requested"},
    {"user.oidc_identity_step_up_failed", "Sign-in method confirmation failed"},
    {"user.oidc_identity_step_up_rate_limited", "Sign-in method confirmation limit reached"},
    {"user.email_change_rate_limited", "Email change request limit reached"},
    {"user.email_changed", "Email changed"},
    {"user.inbox_step_up_rate_limited", "Email verification attempt limit reached"},
    {"user.profile_updated", "Profile updated"},
    {"user.updated_by_admin", "Profile edited by admin"},
    {"user.magic_link_issued", "Sign-in link created"},
    {"user.mfa_enrollment_requested", "MFA enrollment requested"},
    {"user.mfa_enrollment_failed", "MFA enrollment confirmation failed"},
    {"user.mfa_enabled", "MFA enabled"},
    {"user.mfa_disabled", "MFA disabled"},
    {"user.mfa_verified", "MFA verified"},
    {"user.mfa_failed", "MFA verification failed"},
    {"user.mfa_rate_limited", "MFA request limit reached"},
    {"user.mfa_recovery_code_used", "MFA recovery code used"},
    {"user.mfa_recovery_codes_regenerated", "MFA recovery codes regenerated"},
    {"user.mfa_reset_by_admin", "MFA reset by admin"},
    {"user.session_revoked", "Session revoked"},
    {"user.other_sessions_revoked", "Other sessions revoked"},
    {"user.sessions_revoked", "All sessions revoked by admin"},
    {"membership.role_changed", "Member role changed"},
    {"membership.removed", "Member removed"},
    {"membership.erased", "Member’s user account deleted"},
    {"membership.suspended", "Member suspended"},
    {"membership.reinstated", "Member reinstated"},
    {"membership.invitation_accepted", "Invitation accepted"},
    {"membership.invitation_resent", "Invitation resend requested"},
    {"membership.runner_access_changed", "Runner access changed"},
    {"policy.updated", "Policy updated"},
    {"policy.scope_deleted", "Targeted ruleset deleted"},
    {"runbook.created", "Runbook created"},
    {"runbook.updated", "Runbook updated"},
    {"runbook.published", "Runbook published"},
    {"runbook.deleted", "Runbook deleted"},
    {"runbook.dispatched", "Runbook execution requested"},
    {"runbook.execution_succeeded", "Runbook execution succeeded"},
    {"runbook.execution_halted", "Runbook execution halted"},
    {"runbook.execution_cancelled", "Runbook execution cancelled"},
    {"runbook.stage_started", "Runbook stage started"},
    {"runbook.stage_succeeded", "Runbook stage succeeded"},
    {"runbook.stage_halted", "Runbook stage halted"},
    {"runbook.stage_cancelled", "Runbook stage cancelled"},
    {"runbook.item_waiting", "Runbook item waiting"},
    {"runbook.item_succeeded", "Runbook item succeeded"},
    {"runbook.item_failed", "Runbook item failed"},
    {"runbook.item_cancelled", "Runbook item cancelled"},
    {"approval.approved", "Approval granted"},
    {"approval.overridden", "Approval requirements overridden"},
    {"approval.denied", "Approval denied"},
    {"approval.expired", "Approval expired"},
    {"approval.decision_recorded", "Approval decision recorded"},
    {"approval.grant_used", "Standing grant used"},
    {"approval.grant_revoked", "Standing grant revoked"},
    {"run.cancel_requested", "Run cancellation requested"},
    {"action_run.success", "Run succeeded"},
    {"action_run.failed", "Run failed"},
    {"action_run.error", "Run error"},
    {"action_run.validation_failed", "Run validation failed"},
    {"action_run.unknown_action", "Action not found on runner"},
    {"action_run.refused", "Run refused"},
    {"action_run.cancelled", "Run cancelled"},
    {"action_run.timed_out", "Run timed out"},
    {"action_run.denied", "Run denied by policy"},
    {"action_run.pending_approval", "Run awaiting approval"},
    {"user.provisioned_via_sso", "User created (SSO)"},
    {"user.provisioned_via_scim", "User created (SCIM)"},
    {"user.renamed_via_scim", "User renamed (SCIM)"},
    {"membership.renamed_via_scim", "Member display name changed (SCIM)"},
    {"membership.deprovisioned_via_scim", "Member suspended (SCIM)"},
    {"membership.reprovisioned_via_scim", "Member reinstated (SCIM)"},
    {"membership.role_synced_via_scim", "Member role synced (SCIM)"},
    {"membership.runner_access_synced_via_scim", "Member runner access synced (SCIM)"},
    {"sso.group_mapping_created", "SSO group role mapping created"},
    {"sso.group_mapping_updated", "SSO group role mapping updated"},
    {"sso.group_mapping_deleted", "SSO group role mapping deleted"},
    {"sso.group_runner_access_mapping_created", "SSO group runner access mapping created"},
    {"sso.group_runner_access_mapping_updated", "SSO group runner access mapping updated"},
    {"sso.group_runner_access_mapping_deleted", "SSO group runner access mapping deleted"},
    {"sso.provider_configured", "SSO provider configured"},
    {"sso.provider_updated", "SSO provider updated"},
    {"sso.provider_deleted", "SSO provider deleted"},
    {"sso.provider_sign_in_verified", "SSO provider sign-in verified"},
    {"sso.identity_linked", "SSO identity linked"},
    {"sso.identity_unlinked", "SSO identity unlinked"},
    {"sso.existing_user_linked", "SSO identity linked to an existing user"},
    {"sso.link_request_approved", "SSO link request approved"},
    {"sso.link_request_dismissed", "SSO link request dismissed"},
    {"audit.exported", "Audit events read for export"},
    {"audit.retention_swept", "Expired audit events removed"},
    {"subscription.changed", "Subscription updated"},
    {"staff.account_viewed", "Staff viewed account"}
  ]

  def known_event_type_values, do: @known_event_types

  # An event's OUTCOME from its type suffix: a failure or DENIAL (`:danger`), a
  # removal/limit (`:warn`), a pass verdict (`:pass` — the gate saying YES: a
  # run succeeding, an approval landing, a grant or consent letting something
  # through), or routine (`:neutral`). The audit list/detail dots color by this
  # one source, read by both (the web reads it, never copies it). Lifecycle
  # positives (connected, enabled, accepted, confirmed) stay :neutral on
  # purpose: green marks verdicts, not activity, or it becomes wallpaper.
  #
  # A DENIAL is `:danger`, so the trail paints it ROSE exactly as the approvals
  # queue does — the tone table (design-console-ux §2) reads rose as
  # "denied/failed/danger", and one refusal cannot wear two colors on two
  # surfaces. `:warn` keeps what it always meant minus the denials: something
  # existing was taken away or throttled (revoked, deleted, suspended, expired,
  # rate-limited) — a caution to look at, not the gate saying no.
  @danger_suffixes ~w[_failed .failed .error .timed_out _halted .denied .refused .rejected _rejected
                      .unknown_action]
  @warn_suffixes ~w[.revoked _revoked _rate_limited .disabled .deleted _deleted .removed .suspended
                    .expired .cancelled .closed .erased]
  @pass_suffixes ~w[.success .succeeded .approved _approved .grant_used .consent_granted]

  def outcome(event_type) when is_binary(event_type) do
    cond do
      event_type == "oauth.refresh_token_reused" -> :danger
      event_type == "dispatch_blocked_target_unavailable" -> :danger
      event_type == "approval.overridden" -> :warn
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
       {"account.require_mfa_set", "MFA requirement changed"},
       {"account.require_sso_set", "SSO requirement changed"},
       {"account.max_grant_lifetime_set", "Maximum grant lifetime changed"},
       {"account.disabled", "Disabled"},
       {"account.enabled", "Enabled"},
       {"account.closed", "Closed"}
     ]},
    {"Runner",
     [
       {"runner.registered", "Registered"},
       {"runner.connected", "Connected"},
       {"runner.disconnected", "Disconnected"},
       {"runner.disabled", "Disabled"},
       {"runner.credential_rotation_requested", "Key rotation requested"},
       {"runner.credential_rotated", "Replacement key used"},
       {"runner.enabled", "Enabled"},
       {"runner.deleted", "Deleted"},
       {"runner.error", "Error"},
       {"runner.version_rejected", "Connection blocked: unsupported version"},
       {"runner.retention_swept", "Offline runners cleaned up"},
       {"dispatch_blocked_requires_attestation", "Action blocked: signature required"}
     ]},
    {"Pack trust",
     [
       {"pack_trust_baseline_match", "Automatically trusted"},
       {"pack_trust_baseline_mismatch", "Differs from published version"},
       {"pack_trust_baseline_reconciled", "Trusted after catalog update"},
       {"pack_trust_review_required", "Needs review"},
       {"pack_trust_drift_detected", "New contents reported"},
       {"pack_trust_adopted", "Hash trusted"},
       {"pack_trust_rejected", "Hash rejected"},
       {"pack_trust_revoked", "Trust revoked"},
       {"pack_retirement_overridden", "Retirement restriction overridden"},
       {"pack_version_deleted", "Version deleted"},
       {"pack_deleted", "Pack deleted"},
       {"pack_retention_swept", "Unused versions cleaned up"},
       {"pack_retirement_swept", "Retired versions cleaned up"},
       {"dispatch_blocked_pack_untrusted", "Action blocked: pack not trusted"},
       {"dispatch_blocked_pack_retired", "Action blocked: pack version retired"}
     ]},
    {"Enrollment key",
     [
       {"enrollment_key.created", "Created"},
       {"enrollment_key.revoked", "Revoked"},
       {"enrollment_key.bound", "Used for registration"}
     ]},
    {"API key",
     [
       {"api_key.created", "Created"},
       {"api_key.rotation_requested", "Rotation requested"},
       {"api_key.revoked", "Revoked"},
       {"api_key.bound", "Used for the first time"},
       {"api_key.auto_rotated", "Rotation started"},
       {"api_key.retired_by_rotation", "Previous key revoked after rotation"},
       {"api_key.device_grant_approved", "Agent connection approved"},
       {"api_key.device_grant_denied", "Agent connection denied"},
       {"oauth.consent_granted", "OAuth client authorized"},
       {"oauth.refresh_token_reused", "Refresh token reused"}
     ]},
    {"Sign-in",
     [
       {"user.signed_up", "Signed up"},
       {"user.signed_in", "Signed in"},
       {"user.signed_out", "Signed out"},
       {"session.account_switched", "Switched to this account"},
       {"user.sign_in_failed", "Sign-in failed"},
       {"user.magic_link_issued", "Sign-in link created"},
       {"user.email_confirmed", "Email confirmed"}
     ]},
    {"User security",
     [
       {"user.email_change_requested", "Email change requested"},
       {"user.email_change_code_failed", "Email change confirmation failed"},
       {"user.oidc_identity_step_up_requested", "Sign-in method confirmation requested"},
       {"user.oidc_identity_step_up_failed", "Sign-in method confirmation failed"},
       {"user.oidc_identity_step_up_rate_limited", "Sign-in method confirmation limit reached"},
       {"user.email_change_rate_limited", "Email change request limit reached"},
       {"user.email_changed", "Email changed"},
       {"user.inbox_step_up_rate_limited", "Email verification attempt limit reached"},
       {"user.profile_updated", "Profile updated"},
       {"user.updated_by_admin", "Profile edited by admin"},
       {"user.mfa_enrollment_requested", "MFA enrollment requested"},
       {"user.mfa_enrollment_failed", "MFA enrollment confirmation failed"},
       {"user.mfa_enabled", "MFA enabled"},
       {"user.mfa_disabled", "MFA disabled"},
       {"user.mfa_verified", "MFA verified"},
       {"user.mfa_failed", "MFA verification failed"},
       {"user.mfa_rate_limited", "MFA request limit reached"},
       {"user.mfa_recovery_code_used", "MFA recovery code used"},
       {"user.mfa_recovery_codes_regenerated", "MFA recovery codes regenerated"},
       {"user.mfa_reset_by_admin", "MFA reset by admin"},
       {"user.session_revoked", "Session revoked"},
       {"user.other_sessions_revoked", "Other sessions revoked"},
       {"user.sessions_revoked", "All sessions revoked by admin"}
     ]},
    {"Team",
     [
       {"user.invited", "Invited"},
       {"user.invitation_accepted", "Invitation accepted"},
       {"membership.invitation_accepted", "Invitation accepted (existing user)"},
       {"membership.invitation_resent", "Invitation resend requested"},
       {"membership.role_changed", "Role changed"},
       {"membership.removed", "Member removed"},
       {"membership.erased", "User account deleted"},
       {"membership.suspended", "Member suspended"},
       {"membership.reinstated", "Member reinstated"},
       {"membership.runner_access_changed", "Runner access changed"}
     ]},
    {"Policy",
     [
       {"policy.updated", "Updated"},
       {"policy.scope_deleted", "Targeted ruleset deleted"}
     ]},
    {"Runbook",
     [
       {"runbook.created", "Created"},
       {"runbook.updated", "Updated"},
       {"runbook.published", "Published"},
       {"runbook.deleted", "Deleted"},
       {"runbook.dispatched", "Execution requested"},
       {"runbook.execution_succeeded", "Execution succeeded"},
       {"runbook.execution_halted", "Execution halted"},
       {"runbook.execution_cancelled", "Execution cancelled"},
       {"runbook.stage_started", "Stage started"},
       {"runbook.stage_succeeded", "Stage succeeded"},
       {"runbook.stage_halted", "Stage halted"},
       {"runbook.stage_cancelled", "Stage cancelled"},
       {"runbook.item_waiting", "Item waiting"},
       {"runbook.item_succeeded", "Item succeeded"},
       {"runbook.item_failed", "Item failed"},
       {"runbook.item_cancelled", "Item cancelled"}
     ]},
    {"Approval",
     [
       {"approval.approved", "Granted"},
       {"approval.overridden", "Requirements overridden"},
       {"approval.denied", "Denied"},
       {"approval.expired", "Expired"},
       {"approval.decision_recorded", "Decision recorded"},
       {"approval.grant_used", "Standing grant used"},
       {"approval.grant_revoked", "Standing grant revoked"}
     ]},
    {"Run",
     [
       {"run.cancel_requested", "Cancellation requested"},
       {"dispatch_blocked_target_unavailable", "Action request rejected"},
       {"action_run.success", "Succeeded"},
       {"action_run.failed", "Failed"},
       {"action_run.error", "Error"},
       {"action_run.validation_failed", "Validation failed"},
       {"action_run.unknown_action", "Action not found"},
       {"action_run.refused", "Refused"},
       {"action_run.cancelled", "Cancelled"},
       {"action_run.timed_out", "Timed out"},
       {"action_run.denied", "Denied by policy"},
       {"action_run.pending_approval", "Awaiting approval"}
     ]},
    {"SSO / Directory",
     [
       {"user.provisioned_via_sso", "User created (SSO)"},
       {"user.provisioned_via_scim", "User created (SCIM)"},
       {"user.renamed_via_scim", "User renamed (SCIM)"},
       {"membership.renamed_via_scim", "Member display name changed"},
       {"membership.deprovisioned_via_scim", "Member suspended"},
       {"membership.reprovisioned_via_scim", "Member reinstated"},
       {"membership.role_synced_via_scim", "Role synced"},
       {"membership.runner_access_synced_via_scim", "Runner access synced"},
       {"sso.group_mapping_created", "Group role mapping created"},
       {"sso.group_mapping_updated", "Group role mapping updated"},
       {"sso.group_mapping_deleted", "Group role mapping deleted"},
       {"sso.group_runner_access_mapping_created", "Group runner access mapping created"},
       {"sso.group_runner_access_mapping_updated", "Group runner access mapping updated"},
       {"sso.group_runner_access_mapping_deleted", "Group runner access mapping deleted"},
       {"sso.provider_configured", "Provider configured"},
       {"sso.provider_updated", "Provider updated"},
       {"sso.provider_deleted", "Provider deleted"},
       {"sso.provider_sign_in_verified", "Provider sign-in verified"},
       {"sso.identity_linked", "Identity linked"},
       {"sso.identity_unlinked", "Identity unlinked"},
       {"sso.existing_user_linked", "Identity linked to an existing user"},
       {"sso.link_request_approved", "Link request approved"},
       {"sso.link_request_dismissed", "Link request dismissed"}
     ]},
    {"Audit",
     [
       {"audit.exported", "Read for export"},
       {"audit.retention_swept", "Expired events removed"}
     ]},
    {"Billing",
     [
       {"subscription.changed", "Updated"}
     ]},
    {"Emisar staff",
     [
       {"staff.account_viewed", "Viewed account"}
     ]}
  ]

  def grouped_event_type_values, do: @grouped_event_types

  # The finance seat's slice of the trail. Derived from the "Billing" GROUP
  # above rather than a second hand-kept list, so a new billing event type is
  # visible to a billing manager the moment it joins the group operators
  # already filter by — the same low-drift rule `@category_of_group` follows.
  @billing_event_types for {"Billing", options} <- @grouped_event_types,
                           {value, _label} <- options,
                           do: value

  @doc """
  The event types a billing-scoped reader may see — the "Billing" group's types.
  `Audit.Authorizer.for_subject/2` is what applies it; this is the set, pinned in
  `Emisar.AuditTest` so the narrowing can't silently change.
  """
  def billing_event_types, do: @billing_event_types

  # Actor/target vocabularies for event types exposed to a NARROWED reader.
  # Full-trail readers keep the complete static filters, so only a type that
  # joins a restricted readable slice needs an entry. A missing entry fails
  # OPEN at the presentation layer (the complete kind vocabulary stays shown),
  # while the billing-manager role test pins this slice to the exact compact
  # surface so a newly-added Billing type cannot ship without declaring its
  # usable kinds. Row authorization remains in Authorizer.for_subject/2.
  @kind_values_by_event_type %{
    "subscription.changed" => %{
      actor_kind: ["system"],
      target_kind: ["account"]
    }
  }

  # Each domain group belongs to exactly ONE review CATEGORY — the coarse lens
  # the audit page's quick-filter chips + panel facet narrow by. Deriving from
  # the existing groups (not a second per-type taxonomy) keeps it low-drift: a
  # new event type inherits its category from the group it already joins; only a
  # brand-new GROUP needs a line here (the query test asserts total coverage).
  # "Fleet" is the runner connect/disconnect churn the decisions/access/activity
  # lenses let a reviewer step around (UI-017) — de-emphasized as a VIEW, never
  # dropped from the append-only record.
  @category_of_group %{
    "Approval" => "decisions",
    "Policy" => "decisions",
    "Pack trust" => "decisions",
    "Account" => "access",
    "Enrollment key" => "access",
    "API key" => "access",
    "Sign-in" => "access",
    "User security" => "access",
    "Team" => "access",
    "SSO / Directory" => "access",
    "Runbook" => "activity",
    "Run" => "activity",
    "Runner" => "fleet",
    "Audit" => "admin",
    "Billing" => "admin",
    "Emisar staff" => "admin"
  }

  @categories [
    {"decisions", "Decisions"},
    {"access", "Access"},
    {"activity", "Activity"},
    {"fleet", "Fleet"},
    {"admin", "Admin"}
  ]

  @doc "The review-category filter's `{value, label}` options — also drives the audit page's category chips."
  def category_values, do: @categories

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
  # value from a programmatic caller).
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

  @doc "Distinct non-null actor kinds present in the scoped audit query."
  def distinct_actor_kinds(queryable \\ all()) do
    queryable
    |> where([events: e], not is_nil(e.actor_kind))
    |> select([events: e], e.actor_kind)
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

  def by_target_ids(queryable, ids) when is_list(ids),
    do: where(queryable, [events: e], e.target_id in ^ids)

  def by_target_kind(queryable, kind),
    do: where(queryable, [events: e], e.target_kind == ^kind)

  def by_actor_id(queryable, id),
    do: where(queryable, [events: e], e.actor_id == ^id)

  @doc "A query that matches no audit events."
  def none(queryable), do: where(queryable, false)

  @doc "Distinct non-null target kinds present in the scoped audit query."
  def distinct_target_kinds(queryable \\ all()) do
    queryable
    |> where([events: e], not is_nil(e.target_kind))
    |> select([events: e], e.target_kind)
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

  # Retention: a row is prunable once it reaches its stamped `retain_until`.
  # A null horizon never matches, so such a row would never be pruned — which is
  # why the changeset REQUIRES the stamp rather than leaving it to the builder,
  # and why the sweep's index can stay partial on `retain_until IS NOT NULL`.
  def retention_expired(queryable, %DateTime{} = now),
    do: where(queryable, [events: e], e.retain_until <= ^now)

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

  def select_event_types(queryable \\ all()),
    do: select(queryable, [events: e], e.event_type)

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

  @doc """
  Narrows to exactly `types` — the row scope `Audit.Authorizer.for_subject/2`
  applies to a subject that may not read the whole trail.

  Deliberately NOT built on `by_event_types/2`, whose empty list means "every
  type": an empty readable set there would hand a narrowed reader the whole
  audit log. Its own `in` fails closed instead — no types, no rows.
  """
  def only_event_types(queryable, types) when is_list(types),
    do: where(queryable, [events: e], e.event_type in ^types)

  # Hard-cap; the controller validates the user-supplied limit against
  # @max_export_limit and passes it through, so this stays a one-liner.
  def limit_to(queryable, n) when is_integer(n) and n > 0,
    do: limit(queryable, ^n)

  # -- Pagination / filters --------------------------------------------

  @impl Emisar.Repo.Query
  def cursor_fields,
    do: [{:events, :desc, :occurred_at}, {:events, :asc, :id}]

  @actor_kind_values [
    {"user", "User"},
    {"staff", "Emisar staff"},
    {"api_key", "API key"},
    {"runner", "Runner"},
    {"runbook", "Runbook"},
    {"scheduler", "Scheduler"},
    {"system", "System"}
  ]

  @target_kind_values [
    {"user", "User"},
    {"account", "Account"},
    {"runner", "Runner"},
    {"api_key", "API key"},
    {"enrollment_key", "Enrollment key"},
    {"approval_request", "Approval"},
    {"approval_grant", "Standing grant"},
    {"runbook", "Runbook"},
    {"policy", "Policy"},
    {"pack_version", "Pack version"},
    {"identity_provider", "Identity provider"}
  ]

  @impl Emisar.Repo.Query
  def filters,
    do: [
      # `span` lays the filters out as a stacked panel (LiveTable's two-column
      # grid): Category/Type, From/To, then Request ID,
      # Sign-in method, Actor type, and Subject each on their own line. Request
      # ID + Sign-in method are CONDITIONAL — the audit LiveView drops them for
      # event types that never carry a request context / a sign-in (see
      # applicable_filters/2), so they show only when they can actually match.
      # Inclusive date bounds (a "From 10:00" pick includes 10:00:00).
      # Category narrows the Type choices beside it. The quick chips drive the
      # same facet, so both controls use the same event taxonomy.
      %Filter{
        name: :category,
        title: "Category",
        type: {:list, :string},
        span: :half,
        values: category_values(),
        fun: fn queryable, categories ->
          types = event_types_for_categories(categories)
          {queryable, dynamic([events: e], e.event_type in ^types)}
        end
      },
      %Filter{
        name: :event_type,
        title: "Event type",
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
        values: @actor_kind_values,
        valid_values: @actor_kind_values,
        fun: fn queryable, kinds -> {queryable, dynamic([events: e], e.actor_kind in ^kinds)} end
      },
      %Filter{
        name: :target_kind,
        title: "Target type",
        type: {:list, :string},
        # :row_start — mirrors Actor type; the revealed Subject value picker pairs
        # in the cell beside it.
        span: :row_start,
        values: @target_kind_values,
        valid_values: @target_kind_values,
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
      {false, false, true, "An account and its owner membership were created."},
    "account.updated" => {true, true, true, "Account details or settings changed."},
    "account.require_mfa_set" => {true, true, true, "The requirement to use MFA changed."},
    "account.require_sso_set" => {true, true, true, "The requirement to use SSO changed."},
    "account.max_grant_lifetime_set" =>
      {true, true, true,
       "The maximum standing-grant lifetime changed, or standing grants were disabled."},
    "account.disabled" =>
      {false, false, true, "Emisar staff suspended this workspace — its members are signed out."},
    "account.enabled" => {false, false, true, "Emisar staff lifted a workspace suspension."},
    "account.closed" =>
      {true, true, true, "The account was closed after subscription cleanup completed."},
    "runner.registered" => {true, false, false, "A runner registered with emisar."},
    "runner.connected" => {false, false, false, "A runner connected to emisar."},
    "runner.disconnected" => {false, false, false, "A runner disconnected from emisar."},
    "runner.disabled" =>
      {true, true, true, "An operator disabled a runner — dispatches to it are refused."},
    "runner.credential_rotation_requested" =>
      {true, true, true, "An operator requested an early runner connection-key rotation."},
    "runner.credential_rotated" =>
      {true, false, false,
       "The runner authenticated with a replacement connection key for the first time. The previous key keeps its remaining grace period."},
    "runner.enabled" =>
      {true, true, true, "An operator re-enabled a previously disabled runner."},
    "runner.deleted" =>
      {true, true, true, "An operator removed a runner from the fleet (audit history is kept)."},
    "runner.error" =>
      {true, false, false, "A runner reported an error. The event records its code and message."},
    "runner.version_rejected" =>
      {true, false, false,
       "A runner was refused because its version is below the enforced minimum."},
    "runner.retention_swept" =>
      {false, false, true,
       "Runners offline beyond the cleanup period were removed. Disabled runners were kept."},
    "enrollment_key.created" => {true, true, true, "A runner enrollment key was created."},
    "enrollment_key.revoked" =>
      {true, true, true,
       "An operator revoked a runner enrollment key — future registrations with it fail."},
    "enrollment_key.bound" =>
      {true, false, true, "A runner setup key was used for registration for the first time."},
    "api_key.created" =>
      {true, true, true, "An API key was created for an AI agent or audit export."},
    "api_key.rotation_requested" =>
      {true, true, true, "An operator requested automatic rotation on the agent's next call."},
    "api_key.revoked" =>
      {true, true, true, "An operator revoked an API key — its next call gets a 401."},
    "api_key.bound" =>
      {true, false, true, "An automatically generated API key was used for the first time."},
    "api_key.auto_rotated" =>
      {true, false, true,
       "A replacement key was created through automatic rotation. The previous key is revoked when its replacement is first used."},
    "api_key.retired_by_rotation" =>
      {true, false, true,
       "A rotated key's successor was used for the first time — the key it replaces was revoked automatically."},
    "api_key.device_grant_approved" =>
      {true, true, true,
       "A user approved an agent’s connection request. The installer can now collect its key."},
    "api_key.device_grant_denied" =>
      {true, true, true, "An operator denied an agent's connect request — no key was issued."},
    "oauth.consent_granted" =>
      {true, true, true, "A user authorized an OAuth client to act on their behalf."},
    "oauth.refresh_token_reused" =>
      {false, false, true,
       "A spent OAuth refresh token was presented again, so the connection was revoked."},
    "pack_trust_baseline_match" =>
      {false, false, true,
       "A runner reported a pack whose content hash matches the published catalog, so it was trusted automatically."},
    "pack_trust_baseline_mismatch" =>
      {false, false, true,
       "A runner reported different contents for a published pack version. The published hash was kept while the reported hash awaits review."},
    "pack_trust_baseline_reconciled" =>
      {false, false, true,
       "A previously unrecognized pack now matches the published catalog and was trusted automatically."},
    "pack_trust_review_required" =>
      {false, false, true,
       "A reported pack version was not recognized in the published catalog and needs a trust decision."},
    "pack_trust_drift_detected" =>
      {false, false, true,
       "A runner reported new contents for a known pack version. The new hash needs review."},
    "pack_trust_adopted" =>
      {true, true, true, "A user trusted this content hash for the pack version."},
    "pack_trust_rejected" =>
      {true, true, true,
       "A user rejected the reported hash. Any previously trusted hash was kept."},
    "pack_trust_revoked" =>
      {true, true, true,
       "An operator revoked trust in a pack version — dispatches with it are refused."},
    "pack_version_deleted" =>
      {true, true, true,
       "A pack version’s catalog records were removed. Pack files on runners were not removed."},
    "pack_deleted" =>
      {true, true, true,
       "The recorded versions of a pack were removed from the account’s catalog. Pack files on runners were not removed."},
    "pack_retention_swept" =>
      {false, false, true, "Pack versions not reported within the cleanup period were removed."},
    "pack_retirement_swept" =>
      {false, false, true, "Retired pack versions no longer reported by runners were removed."},
    "pack_retirement_overridden" =>
      {true, true, true,
       "A user removed the retirement restriction from this trusted pack version. Other action rules still apply."},
    "dispatch_blocked_pack_untrusted" =>
      {true, true, true, "An action was blocked because its pack was not trusted."},
    "dispatch_blocked_pack_retired" =>
      {true, true, true, "An action was blocked because its pack version was retired."},
    "dispatch_blocked_requires_attestation" =>
      {true, true, true, "An action was blocked because the required signature was missing."},
    "dispatch_blocked_target_unavailable" =>
      {true, true, false,
       "An action request was rejected because its target was unavailable to the requester."},
    "user.signed_up" => {false, false, false, "A new user registered with emisar."},
    "user.signed_in" =>
      {true, false, false,
       "A user signed in to emisar. The summary shows the sign-in method when recorded."},
    "user.signed_out" => {true, false, false, "A user ended their session."},
    "session.account_switched" =>
      {false, false, false,
       "A user switched to this account. The role shown is the role they held here at the time."},
    "user.sign_in_failed" =>
      {true, false, false, "A sign-in attempt failed (wrong or expired code, bad link)."},
    "user.invited" => {true, true, true, "An admin invited a teammate into the workspace."},
    "user.invitation_accepted" =>
      {true, false, false, "An invitee accepted and registered a new user account."},
    "user.email_confirmed" =>
      {true, false, false, "A user proved ownership of their email address."},
    "user.email_change_requested" =>
      {true, true, false, "A user asked to change their sign-in email (confirmation pending)."},
    "user.email_change_code_failed" =>
      {true, false, false, "An emailed email-change confirmation code was wrong or expired."},
    "user.oidc_identity_step_up_requested" =>
      {true, true, false,
       "A user requested confirmation before linking, removing, or testing an SSO sign-in method."},
    "user.oidc_identity_step_up_failed" =>
      {true, false, false,
       "An emailed SSO sign-in method confirmation code was wrong or expired."},
    "user.oidc_identity_step_up_rate_limited" =>
      {true, false, false,
       "An SSO sign-in method confirmation was refused after the user reached its limit."},
    "user.email_change_rate_limited" =>
      {true, false, false,
       "An email-change code delivery was refused after the user reached its limit."},
    "user.email_changed" => {true, false, false, "A user's sign-in email change completed."},
    "user.inbox_step_up_rate_limited" =>
      {true, false, false,
       "A current-inbox credential proof was refused after the user reached its attempt limit."},
    "user.profile_updated" => {true, true, false, "A user edited their own profile."},
    "user.updated_by_admin" => {true, true, true, "An admin edited a teammate's profile."},
    "user.magic_link_issued" => {true, false, false, "A sign-in link and code were created."},
    "user.mfa_enrollment_requested" =>
      {true, false, false,
       "A user requested a current-inbox challenge before enrolling an authenticator."},
    "user.mfa_enrollment_failed" =>
      {true, false, false, "An emailed MFA-enrollment confirmation code was wrong or expired."},
    "user.mfa_enabled" => {true, true, false, "A user enrolled a second factor."},
    "user.mfa_disabled" => {true, true, false, "A user disabled their MFA."},
    "user.mfa_verified" =>
      {true, true, false,
       "An MFA code was accepted, or an existing session was marked MFA-verified."},
    "user.mfa_failed" => {true, false, false, "An MFA verification attempt failed."},
    "user.mfa_rate_limited" =>
      {true, false, false,
       "A user reached an MFA credential limit and another attempt was refused."},
    "user.mfa_recovery_code_used" =>
      {true, false, false, "A one-time recovery code was spent to pass the second factor."},
    "user.mfa_recovery_codes_regenerated" =>
      {true, true, false, "A user regenerated their recovery codes (old ones invalidated)."},
    "user.session_revoked" => {true, true, false, "A user revoked one of their own sessions."},
    "user.other_sessions_revoked" =>
      {true, true, false, "A user revoked every session except the current one."},
    "user.sessions_revoked" => {true, true, true, "An admin revoked a teammate's sessions."},
    "user.mfa_reset_by_admin" =>
      {true, true, true, "An admin cleared a teammate's second factor so they can re-enroll."},
    "membership.role_changed" => {true, true, true, "An admin changed a member's role."},
    "membership.removed" => {true, true, true, "An admin removed a member from the workspace."},
    "membership.erased" =>
      {false, false, true,
       "Emisar staff erased this member's user account, so their seat here went with it."},
    "membership.suspended" =>
      {true, true, true, "An admin suspended a member — they can't sign into this workspace."},
    "membership.reinstated" => {true, true, true, "An admin reinstated a suspended member."},
    "membership.invitation_accepted" =>
      {true, false, false, "An existing user accepted an invitation into this workspace."},
    "membership.invitation_resent" =>
      {true, true, true,
       "A user requested a fresh invitation. This does not confirm email delivery."},
    "membership.runner_access_changed" =>
      {true, true, true, "An admin changed which runners a member may target."},
    "policy.updated" =>
      {true, true, true, "Default rules, action overrides, or approval requirements changed."},
    "policy.scope_deleted" =>
      {true, true, true,
       "A runner or group ruleset was deleted. The remaining applicable rules determine the policy."},
    "runbook.created" => {true, true, true, "An operator created a runbook draft."},
    "runbook.updated" => {true, true, true, "A runbook draft was saved or discarded."},
    "runbook.published" =>
      {true, true, true, "An operator published a runbook version for dispatch."},
    "runbook.deleted" => {true, true, true, "An operator deleted a runbook."},
    "runbook.dispatched" =>
      {true, true, true,
       "A runbook execution was requested. It may need approval before its actions can start."},
    "runbook.execution_succeeded" =>
      {false, false, true, "Every logical item succeeded and the runbook execution completed."},
    "runbook.execution_halted" =>
      {false, false, true, "A blocking outcome halted the runbook before later work could start."},
    "runbook.execution_cancelled" =>
      {true, true, true, "An operator cancelled the runbook execution."},
    "runbook.stage_started" =>
      {false, false, true, "The scheduler made a stage eligible and began dispatching its items."},
    "runbook.stage_succeeded" => {false, false, true, "Every logical item in a stage succeeded."},
    "runbook.stage_halted" =>
      {false, false, true, "A blocking outcome halted the current stage."},
    "runbook.stage_cancelled" =>
      {true, true, true, "An operator cancellation closed a pending or active stage."},
    "runbook.item_waiting" =>
      {false, false, true, "A successful observation did not yet meet its declared conditions."},
    "runbook.item_succeeded" =>
      {false, false, true, "A logical step and runner item met every success condition."},
    "runbook.item_failed" =>
      {false, false, true, "A logical step and runner item reached a terminal failure."},
    "runbook.item_cancelled" =>
      {true, true, true, "An operator cancellation closed a logical runbook item."},
    "approval.approved" =>
      {true, true, true,
       "An approval request was granted, optionally with a standing grant for an action."},
    "approval.overridden" =>
      {true, true, true,
       "An owner or admin released held work without the remaining required reviews."},
    "approval.denied" => {true, true, true, "An approval request was denied."},
    "approval.expired" =>
      {false, false, true, "An approval request expired before receiving all required approvals."},
    "approval.decision_recorded" =>
      {true, true, true,
       "An approver approved or denied a request. Final approval or denial is recorded separately."},
    "approval.grant_used" =>
      {true, false, true, "A standing grant auto-approved a matching action."},
    "approval.grant_revoked" =>
      {true, true, true,
       "A standing grant was revoked by a user or because its approver’s membership changed."},
    "run.cancel_requested" => {true, true, true, "Someone requested cancellation of a run."},
    "action_run.success" =>
      {true, false, true, "A dispatched action completed successfully on its runner."},
    "action_run.failed" =>
      {true, false, true,
       "An action failed, or the runner returned an unrecognized result status."},
    "action_run.error" =>
      {true, false, true, "A dispatched action errored before/while executing."},
    "action_run.validation_failed" =>
      {true, false, true, "The action’s input or output did not pass validation."},
    "action_run.unknown_action" =>
      {true, false, true, "A runner reported it does not have the dispatched action."},
    "action_run.refused" =>
      {true, false, true,
       "An action was refused by emisar or the runner because an execution requirement was not met."},
    "action_run.cancelled" =>
      {true, false, true, "A run was cancelled before or during execution."},
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
    "membership.renamed_via_scim" =>
      {false, false, true,
       "The identity provider changed the name this account shows for a member."},
    "membership.deprovisioned_via_scim" =>
      {true, false, true,
       "The identity provider deprovisioned a member (suspended, sessions killed)."},
    "membership.reprovisioned_via_scim" =>
      {true, false, true, "The identity provider re-activated a previously deprovisioned member."},
    "membership.role_synced_via_scim" =>
      {true, false, true, "A member's role was recomputed from directory group mappings."},
    "membership.runner_access_synced_via_scim" =>
      {true, false, true,
       "A member's runner access was recomputed from directory group mappings."},
    "sso.group_mapping_created" =>
      {true, true, true, "An admin mapped a directory group to a workspace role."},
    "sso.group_mapping_updated" =>
      {true, true, true, "An admin changed a directory-group role mapping."},
    "sso.group_mapping_deleted" =>
      {true, true, true, "An admin removed a directory-group role mapping."},
    "sso.group_runner_access_mapping_created" =>
      {true, true, true, "An admin mapped a directory group to runner access."},
    "sso.group_runner_access_mapping_updated" =>
      {true, true, true, "An admin changed a directory-group runner-access mapping."},
    "sso.group_runner_access_mapping_deleted" =>
      {true, true, true, "An admin removed a directory-group runner-access mapping."},
    "sso.provider_configured" => {true, true, true, "An admin configured an identity provider."},
    "sso.provider_sign_in_verified" =>
      {true, true, true, "An admin completed an OIDC sign-in verification."},
    "sso.identity_linked" =>
      {true, true, true, "A user verified and linked an SSO identity to their profile."},
    "sso.identity_unlinked" =>
      {true, true, true, "A user removed a verified SSO identity from their profile."},
    "sso.existing_user_linked" =>
      {true, true, true, "An admin linked an IdP identity to an existing emisar user."},
    "sso.provider_updated" =>
      {true, true, true, "An admin changed an identity provider's configuration."},
    "sso.provider_deleted" => {true, true, true, "An admin removed an identity provider."},
    "sso.link_request_approved" =>
      {true, true, true, "An admin approved an SSO request and created a user."},
    "sso.link_request_dismissed" =>
      {true, true, true, "An admin dismissed an SSO request without adding or linking a user."},
    "audit.exported" =>
      {true, false, true,
       "Audit events were read for CSV or API export. This does not confirm a complete download or delivery to a SIEM."},
    "audit.retention_swept" =>
      {false, false, false, "Audit events past their retention period were removed."},
    "subscription.changed" =>
      {false, false, true,
       "The subscription’s plan, status, paid access, or scheduled changes were updated."},
    "staff.account_viewed" =>
      {false, false, true, "Emisar staff opened this workspace in the internal support console."}
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

    filters
    |> category_type_choices(params["category"])
    |> Enum.reject(fn filter ->
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

  @doc "Keeps selected event types or groups that belong to the selected categories."
  def compatible_event_types(type_param, category_param) do
    types = nonblank_values(type_param)

    case nonblank_values(category_param) do
      [] ->
        types

      categories ->
        allowed = MapSet.new(event_types_for_categories(categories))
        Enum.filter(types, &reaches?(:event_type, &1, allowed))
    end
  end

  defp category_type_choices(filters, category_param) do
    case nonblank_values(category_param) do
      [] ->
        filters

      categories ->
        allowed = MapSet.new(event_types_for_categories(categories))

        Enum.map(filters, fn
          %Filter{name: :event_type} = filter -> narrow_filter_values(filter, allowed)
          filter -> filter
        end)
    end
  end

  defp nonblank_values(param), do: param |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))

  @event_type_vocabulary_filter_names [:category, :event_type]
  @kind_filter_names [:actor_kind, :target_kind]

  @doc """
  The filters a reader narrowed to `readable` event types can actually use.

  Each vocabulary-bearing filter keeps only the values that can still match a
  readable type, and one left with no value that NARROWS is dropped — nothing
  selectable, or a single choice that just returns the reader's whole slice.
  This applies to event taxonomy and actor/target kinds alike. An option that
  can only ever come back empty, or change nothing, is not a filter.

  `readable` is `Audit.Authorizer.readable_event_types/1` — the same judgment
  `for_subject/2` scopes the ROWS by — so an offered option always has rows
  behind it, and narrowing a role stays one edit.

  `valid_values` is deliberately left at the FULL vocabulary. It is what a
  programmatic `event_type` param is validated against, and narrowing it would
  turn a filter naming a withheld type into a dropped param — i.e. the reader's
  whole slice — where the row scope gives it the zero rows it should.
  """
  def readable_filters(filters, :all), do: filters

  def readable_filters(filters, readable) do
    allowed = MapSet.new(readable)

    filters
    |> Enum.map(&narrow_filter_values(&1, allowed))
    |> Enum.reject(&cannot_narrow?(&1, allowed))
  end

  @doc """
  Narrows the Actor type and Target type presentation values to kinds that are
  present in this account's readable rows. The full `valid_values` stay intact,
  so a crafted URL still applies as an empty-result filter instead of being
  dropped. A currently-applied kind keeps its control visible for clearing.
  """
  def present_kind_filters(filters, logged_kinds, params) do
    Enum.flat_map(filters, fn
      %Filter{name: name} = filter when name in @kind_filter_names ->
        logged = logged_kinds |> Map.get(name, []) |> MapSet.new()
        values = Enum.filter(filter.values, &MapSet.member?(logged, elem(&1, 0)))
        filter = %{filter | values: values, valid_values: filter.valid_values || filter.values}

        if length(values) >= 2 or param_present?(params, name), do: [filter], else: []

      %Filter{} = filter ->
        [filter]
    end)
  end

  defp narrow_filter_values(%Filter{name: :event_type} = filter, allowed) do
    groups =
      for {group_label, options} <- filter.values,
          kept = Enum.filter(options, &reaches?(:event_type, elem(&1, 0), allowed)),
          kept != [],
          do: {group_label, kept}

    %{filter | values: groups}
  end

  defp narrow_filter_values(%Filter{name: :category} = filter, allowed) do
    %{filter | values: Enum.filter(filter.values, &reaches?(:category, elem(&1, 0), allowed))}
  end

  defp narrow_filter_values(%Filter{name: name} = filter, allowed)
       when name in @kind_filter_names do
    case readable_kind_values(name, allowed) do
      :unknown -> filter
      kinds -> %{filter | values: Enum.filter(filter.values, &MapSet.member?(kinds, elem(&1, 0)))}
    end
  end

  defp narrow_filter_values(%Filter{} = filter, _allowed), do: filter

  # A value narrows when what it selects is a NON-EMPTY, PROPER subset of the
  # readable set: empty means it can only return zero rows, and equal means
  # picking it changes nothing the reader can already see.
  defp cannot_narrow?(%Filter{name: name} = filter, allowed)
       when name in @event_type_vocabulary_filter_names do
    not Enum.any?(selections(filter), fn selected ->
      reach = MapSet.intersection(selected, allowed)
      not Enum.empty?(reach) and not MapSet.equal?(reach, allowed)
    end)
  end

  defp cannot_narrow?(%Filter{name: name, values: values}, _allowed)
       when name in @kind_filter_names,
       do: length(values) < 2

  defp cannot_narrow?(%Filter{}, _allowed), do: false

  defp readable_kind_values(name, allowed) do
    Enum.reduce_while(allowed, MapSet.new(), fn type, acc ->
      case get_in(@kind_values_by_event_type, [type, name]) do
        nil -> {:halt, :unknown}
        kinds -> {:cont, MapSet.union(acc, MapSet.new(kinds))}
      end
    end)
  end

  defp selections(%Filter{name: :event_type} = filter) do
    for {_group_label, options} <- filter.values,
        {value, _label, _description} <- options,
        do: selected_types(:event_type, value)
  end

  defp selections(%Filter{name: name} = filter),
    do: for({value, _label} <- filter.values, do: selected_types(name, value))

  defp reaches?(name, value, allowed) do
    reach = MapSet.intersection(selected_types(name, value), allowed)
    not Enum.empty?(reach)
  end

  # The event types one filter value actually selects — the same expansion its
  # own `fun` runs at query time, so an option's advertised reach is its real one.
  defp selected_types(:event_type, value), do: MapSet.new(expand_event_type_groups([value]))
  defp selected_types(:category, value), do: MapSet.new(event_types_for_categories([value]))

  defp param_present?(params, name) do
    case Map.get(params, to_string(name)) do
      nil -> false
      "" -> false
      list when is_list(list) -> Enum.any?(list, &(&1 not in [nil, ""]))
      _ -> true
    end
  end

  defp any_type_supports?(types, name), do: Enum.any?(types, &type_supports?(name, &1))

  # The event types in any of the selected review `categories` — each domain
  # group maps to exactly one category (@category_of_group), so this composes
  # every type of every group that falls in the chosen categories.
  defp event_types_for_categories(categories) do
    for {group_label, options} <- @grouped_event_types,
        @category_of_group[group_label] in categories,
        {value, _label} <- options,
        do: value
  end
end
