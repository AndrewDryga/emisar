defmodule EmisarWeb.AuditSummary do
  @moduledoc """
  Short, event-specific summaries of recorded audit facts.

  Values come from the event snapshot, never current account or resource state.
  Missing historical fields are omitted; explicit false and nil values retain
  their meaning. Returns plain text pairs for the shared list/detail rendering.
  """

  alias Emisar.{Audit, Auth}
  alias EmisarWeb.{TimeHelpers, TransportReason}

  @account_fields [
    name: "Name",
    slug: "Slug",
    monthly_report_opt_out: "Monthly reports",
    pack_unseen_retention_days: "Pack cleanup",
    runner_inactive_retention_hours: "Runner cleanup",
    support_slack_url: "Slack support"
  ]

  @provider_fields [
    name: "Name",
    issuer: "Issuer",
    client_id: "Client ID",
    identifier_claim: "Identifier claim",
    provisioner: "Provisioning",
    allowed_email_domain: "Email domain",
    default_role: "Default role",
    enabled: "SSO",
    satisfies_mfa: "SSO satisfies MFA",
    scim_enabled: "Directory sync"
  ]

  @doc "Readable label/value pairs, preserving the recorded event's scope and meaning."
  def summary_pairs(%{event_type: type, payload: payload}) do
    type
    |> summarize(payload || %{})
    |> Enum.map(fn {label, value} -> {summary_label(label), value} end)
  end

  defp summary_label("via"), do: "Using"
  defp summary_label("duration_ms"), do: "Duration"
  defp summary_label("tier defaults"), do: "Default rules"
  defp summary_label("+overrides"), do: "Overrides added"
  defp summary_label("-overrides"), do: "Overrides removed"
  defp summary_label("~overrides"), do: "Overrides changed"

  defp summary_label(label) do
    grapheme = label |> String.replace("_", " ") |> String.next_grapheme()

    case grapheme do
      {first, rest} -> String.upcase(first) <> rest
      nil -> ""
    end
  end

  # -- Account / membership --------------------------------------------

  defp summarize("account.created", p),
    do: pairs(plan: plan_label(get(p, :plan)), slug: get(p, :slug))

  defp summarize("account.updated", p),
    do: setting_changes(map_value(p, :changes), @account_fields)

  defp summarize("account.require_mfa_set", p),
    do: pairs([{"MFA", requirement(get(p, :require_mfa))}])

  defp summarize("account.require_sso_set", p),
    do: pairs([{"SSO", requirement(get(p, :require_sso))}])

  defp summarize("account.max_grant_lifetime_set", p) do
    case fetch(p, :max_grant_lifetime_seconds) do
      {:ok, 0} -> [{"Standing grants", "Disabled"}]
      {:ok, nil} -> [{"Account limit", "Removed"}]
      {:ok, seconds} -> pairs(maximum_lifetime: format_window(seconds))
      :error -> []
    end
  end

  defp summarize(type, p) when type in ["account.disabled", "account.enabled", "account.closed"],
    do: pairs(reason: get(p, :reason))

  defp summarize(type, p)
       when type in ["membership.role_changed", "membership.role_synced_via_scim"],
       do: recorded_change(p, :from, :to, "Role", &role_label/1)

  defp summarize(type, p) when type in ["membership.removed", "membership.erased"],
    do: pairs(previous_role: role_label(get(p, :role)))

  defp summarize(type, p)
       when type in [
              "membership.runner_access_changed",
              "membership.runner_access_synced_via_scim",
              "sso.group_runner_access_mapping_created",
              "sso.group_runner_access_mapping_updated",
              "sso.group_runner_access_mapping_deleted"
            ],
       do: access_changes(p)

  defp summarize("sso.provider_updated", p) do
    setting_changes(map_value(p, :changes), @provider_fields) ++
      flag(p, :client_secret_rotated, "Client secret", "Rotated") ++
      flag(p, :scim_token_issued, "SCIM token", "Created") ++
      flag(p, :scim_token_rotated, "SCIM token", "Rotated") ++
      flag(p, :scim_token_revoked, "SCIM token", "Revoked") ++ access_changes(p)
  end

  defp summarize(type, p)
       when type in [
              "membership.invitation_accepted",
              "user.invitation_accepted",
              "session.account_switched",
              "user.provisioned_via_sso",
              "user.provisioned_via_scim",
              "sso.link_request_approved"
            ],
       do: pairs(role: role_label(get(p, :role)))

  defp summarize(type, p) when type in ["user.invited", "membership.invitation_resent"],
    do: pairs(invited_role: role_label(get(p, :role)))

  defp summarize(type, p)
       when type in ["sso.group_mapping_created", "sso.group_mapping_updated"],
       do: pairs(mapped_role: role_label(get(p, :role)))

  defp summarize("sso.group_mapping_deleted", p),
    do: pairs(mapped_role: role_label(get(p, :role)))

  defp summarize("membership.renamed_via_scim", p),
    do: recorded_change(p, :from, :to, "Name", &display_setting/1)

  # -- Sign-in / sessions / MFA -----------------------------------------

  defp summarize(type, p) when type in ["user.signed_in", "user.email_confirmed"],
    do: pairs(via: sign_in_method(get(p, :method)))

  defp summarize("oauth.refresh_token_reused", _p), do: [{"Connection", "Revoked"}]

  defp summarize(type, p)
       when type in [
              "user.sign_in_failed",
              "user.mfa_failed",
              "user.email_change_code_failed",
              "user.mfa_enrollment_failed"
            ],
       do: pairs(reason: failure_reason(type, get(p, :reason)))

  defp summarize(type, p)
       when type in [
              "user.oidc_identity_step_up_requested",
              "user.oidc_identity_step_up_failed"
            ] do
    pairs(
      for: confirmation_purpose(get(p, :purpose)),
      reason: failure_reason(type, get(p, :reason))
    )
  end

  defp summarize("user.mfa_verified", p) do
    if get(p, :session_verified) == true,
      do: [{"Session", "Verified"}],
      else: pairs(via: factor_label(get(p, :factor)))
  end

  defp summarize(type, p)
       when type in [
              "user.mfa_rate_limited",
              "user.email_change_rate_limited",
              "user.inbox_step_up_rate_limited",
              "user.oidc_identity_step_up_rate_limited"
            ] do
    pairs(
      step: limit_step(get(p, :scope)),
      limit: get(p, :attempt_limit),
      window: format_window(get(p, :window_seconds))
    )
  end

  defp summarize("user.mfa_recovery_code_used", p), do: pairs(codes_left: get(p, :remaining))

  defp summarize("user.other_sessions_revoked", p) do
    case get(p, :count) do
      n when is_integer(n) and n > 0 -> pairs(sessions: n)
      _ -> []
    end
  end

  defp summarize("user.email_changed", p),
    do: recorded_change(p, :from, :to, "Email", &display_setting/1)

  defp summarize(type, p)
       when type in ["user.profile_updated", "user.updated_by_admin", "user.renamed_via_scim"] do
    case fetch(p, :full_name) do
      {:ok, name} when name in [nil, ""] -> [{"Name", "Removed"}]
      {:ok, name} -> pairs(name: name)
      :error -> []
    end
  end

  # -- Runners / enrollment keys / API keys -----------------------------

  defp summarize("runner.registered", p),
    do: pairs(group: get(p, :group), hostname: get(p, :hostname))

  defp summarize("runner.disconnected", p),
    do: pairs(reason: TransportReason.disconnect_message(get(p, :reason)))

  defp summarize("runner.error", p),
    do: pairs(error: get(p, :message) || get(p, :code))

  defp summarize("runner.version_rejected", p),
    do: pairs(version: get(p, :runner_version), minimum: get(p, :minimum))

  defp summarize("runner.retention_swept", p),
    do: pairs(removed: get(p, :count), offline_for: hours(get(p, :inactive_hours)))

  defp summarize("runner.credential_rotated", p) do
    pairs(key: get(p, :token_prefix), replaces: get(p, :previous_token_prefix)) ++
      expiration(p)
  end

  defp summarize("enrollment_key.created", p) do
    pairs(use: key_use(get(p, :reusable)), use_limit: get(p, :max_uses)) ++ expiration(p)
  end

  defp summarize("enrollment_key.revoked", p), do: pairs(prefix: get(p, :prefix))

  defp summarize("enrollment_key.bound", p) do
    pairs(prefix: get(p, :prefix)) ++
      flag(p, :auto, "Source", "Runner setup") ++ reporting_runner(p)
  end

  defp summarize("api_key.created", p) do
    pairs(
      prefix: get(p, :prefix),
      type: key_kind(get(p, :kind)),
      replaces: get(p, :replaces_prefix) || get(p, :replaces_id)
    )
  end

  defp summarize("api_key.revoked", p) do
    pairs(prefix: get(p, :prefix)) ++
      if(is_binary(get(p, :cascade_source_id)),
        do: [{"Reason", "Related key revoked"}],
        else: []
      )
  end

  defp summarize("api_key.bound", p),
    do: pairs(prefix: get(p, :prefix)) ++ flag(p, :auto, "Source", "Created automatically")

  defp summarize(type, p) when type in ["api_key.auto_rotated", "api_key.retired_by_rotation"],
    do: pairs(replacement_key: get(p, :successor_prefix))

  # -- Packs -----------------------------------------------------------

  defp summarize(type, p)
       when type in ["pack_trust_baseline_match", "pack_trust_baseline_reconciled"],
       do: [{"Matches", "Published content hash"}] ++ reporting_runner(p)

  defp summarize(type, p)
       when type in ["pack_trust_baseline_mismatch", "pack_trust_drift_detected"],
       do: [{"Review", "Required"}] ++ reporting_runner(p)

  defp summarize("pack_trust_review_required", p),
    do: [{"Reason", "Not in published catalog"}] ++ reporting_runner(p)

  defp summarize("pack_trust_adopted", p),
    do: flag(p, :retired, "Retirement restriction", "Overridden")

  defp summarize("pack_trust_rejected", p) do
    case fetch(p, :trusted_hash) do
      {:ok, nil} -> [{"Trust", "Pack remains untrusted"}]
      {:ok, hash} when is_binary(hash) and hash != "" -> [{"Trust", "Previous trusted hash kept"}]
      _ -> []
    end
  end

  defp summarize("pack_deleted", p) do
    case fetch(p, :versions) do
      {:ok, versions} when is_list(versions) -> pairs(versions_removed: length(versions))
      _ -> []
    end
  end

  defp summarize("pack_retention_swept", p),
    do: pairs(removed: get(p, :count), not_reported_for: days(get(p, :unseen_days)))

  defp summarize("pack_retirement_swept", p), do: pairs(removed: get(p, :count))

  defp summarize(type, p)
       when type in [
              "dispatch_blocked_pack_untrusted",
              "dispatch_blocked_pack_retired",
              "dispatch_blocked_requires_attestation"
            ],
       do: pairs(action: get(p, :action_id) || get(p, :requested_action_id))

  defp summarize("dispatch_blocked_target_unavailable", p),
    do: pairs(requested_action: get(p, :requested_action_id))

  # -- Runbooks --------------------------------------------------------

  defp summarize("runbook.updated", p) do
    pairs(draft: draft_operation(get(p, :operation))) ++
      recorded_change(p, :from_title, :title, "Title", &display_setting/1)
  end

  defp summarize(type, p) when type in ["runbook.published", "runbook.deleted"],
    do: pairs(version: format_version(get(p, :version)))

  defp summarize("runbook.dispatched", p) do
    pairs(stages: get(p, :stages), items: get(p, :total)) ++
      if(get(p, :status) in [:pending_approval, "pending_approval"],
        do: [{"Approval", "Required"}],
        else: []
      ) ++ pairs(reason: get(p, :reason))
  end

  defp summarize("runbook.execution_halted", p),
    do: pairs(reason: get(p, :message) || get(p, :code))

  defp summarize("runbook.stage_halted", p),
    do: pairs(stage: get(p, :stage_id), reason: get(p, :message) || get(p, :code))

  defp summarize(type, p)
       when type in [
              "runbook.stage_started",
              "runbook.stage_succeeded",
              "runbook.stage_cancelled"
            ],
       do: pairs(stage: get(p, :stage_id))

  defp summarize("runbook.item_failed", p),
    do: item_pairs(p) ++ pairs(reason: get(p, :message) || get(p, :code))

  defp summarize(type, p)
       when type in [
              "runbook.item_waiting",
              "runbook.item_succeeded",
              "runbook.item_cancelled"
            ],
       do: item_pairs(p)

  # -- Approvals / runs ------------------------------------------------

  defp summarize("approval.decision_recorded", p) do
    pairs(
      decision: decision_label(get(p, :decision)),
      approvals: approval_tally(p),
      reason: get(p, :reason)
    )
  end

  defp summarize("approval.approved", p) do
    pairs(
      standing_grant: grant_duration(get(p, :grant_duration)),
      arguments: grant_scope(get(p, :grant_scope)),
      use_limit: get(p, :grant_max_uses),
      reason: get(p, :reason)
    )
  end

  defp summarize("approval.overridden", p) do
    pairs(
      approvals: approval_tally(p),
      approvals_waived: positive(get(p, :remaining_approvals_waived))
    ) ++
      flag(p, :self_approval_waived, "Self-approval restriction", "Waived") ++
      pairs(reason: get(p, :reason))
  end

  defp summarize("approval.denied", p), do: pairs(reason: get(p, :reason))

  defp summarize("approval.grant_used", p),
    do: pairs(action: get(p, :action), uses: grant_uses(p))

  defp summarize("approval.grant_revoked", p),
    do: pairs(action: get(p, :action_id))

  defp summarize("run.cancel_requested", p),
    do: pairs(action: get(p, :action), reason: get(p, :reason))

  # The action is the run's identity. Keep it first and distinguish request
  # justification, policy explanation, and execution errors.
  defp summarize("action_run.success", p),
    do: pairs(action: get(p, :action), duration_ms: format_duration(get(p, :duration_ms)))

  defp summarize("action_run.failed", p) do
    pairs(
      action: get(p, :action),
      exit_code: get(p, :exit_code),
      duration_ms: format_duration(get(p, :duration_ms)),
      error: get(p, :error_message)
    )
  end

  defp summarize("action_run.error", p) do
    pairs(action: get(p, :action), error: get(p, :error_message), exit_code: get(p, :exit_code))
  end

  defp summarize(type, p)
       when type in ["action_run.validation_failed", "action_run.refused"],
       do: pairs(action: get(p, :action), reason: get(p, :error_message))

  defp summarize("action_run.timed_out", p),
    do: pairs(action: get(p, :action), duration_ms: format_duration(get(p, :duration_ms)))

  defp summarize("action_run.denied", p),
    do: pairs(action: get(p, :action), reason: get(p, :policy_reason))

  defp summarize("action_run.pending_approval", p),
    do: pairs(action: get(p, :action), policy: get(p, :policy_reason))

  defp summarize("action_run.cancelled", p),
    do: pairs(action: get(p, :action), reason: cancellation_reason(get(p, :reason)))

  defp summarize("action_run." <> _rest, p), do: pairs(action: get(p, :action))

  # -- Policies / audit / billing --------------------------------------

  defp summarize("policy.updated", p) do
    changes = Audit.policy_changes(p)
    overrides = map_value(changes, :overrides)

    scope_pairs(p) ++
      version_change(p) ++
      pairs(
        "tier defaults": positive(changes |> map_value(:defaults) |> map_size()),
        "+overrides": positive(overrides |> list_value(:added) |> length()),
        "-overrides": positive(overrides |> list_value(:removed) |> length()),
        "~overrides": positive(overrides |> list_value(:changed) |> length())
      ) ++
      policy_approval_changes(map_value(changes, :approval)) ++
      if(get(overrides, :order_changed) == true, do: [{"Override order", "Changed"}], else: [])
  end

  defp summarize("policy.scope_deleted", p), do: scope_pairs(p)

  defp summarize("audit.exported", p) do
    transport =
      case get(p, :transport) do
        "csv" -> [{"Format", "CSV"}]
        "siem" -> [{"Using", "Export API"}]
        _ -> []
      end

    transport ++ pairs(events: get(p, :count))
  end

  defp summarize("audit.retention_swept", p), do: pairs(events: get(p, :count))

  defp summarize("subscription.changed", p) do
    recorded_change(p, :from, :to, "Plan", &plan_label/1) ++
      subscribed_plan_change(p) ++
      recorded_change(p, :from_status, :to_status, "Status", &subscription_status/1) ++
      recorded_change(p, :from_state, :to_state, "Paid access", &paid_access/1) ++
      subscription_schedule(p)
  end

  # Routine lifecycle events need no duplicate status or invented historical fact.
  defp summarize(_type, _payload), do: []

  # -- Helpers ---------------------------------------------------------

  defp item_pairs(p) do
    pairs(
      step: get(p, :step_id),
      runner: get(p, :runner_ref),
      attempt: get(p, :attempt_number)
    )
  end

  defp pairs(values) do
    Enum.flat_map(values, fn {label, value} ->
      case scalar(value) do
        nil -> []
        "" -> []
        text -> [{to_string(label), text}]
      end
    end)
  end

  defp scalar(nil), do: nil
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp scalar(_), do: nil

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_), do: nil

  defp recorded_change(payload, from_key, to_key, label, formatter) do
    case {fetch(payload, from_key), fetch(payload, to_key)} do
      {{:ok, before_value}, {:ok, after_value}} when before_value != after_value ->
        case {formatter.(before_value), formatter.(after_value)} do
          {nil, _} -> []
          {_, nil} -> []
          {value, value} -> []
          {before_text, after_text} -> [{label, "#{before_text} → #{after_text}"}]
        end

      _ ->
        []
    end
  end

  defp setting_changes(changes, fields) do
    Enum.flat_map(fields, fn {key, label} ->
      recorded_change(map_value(changes, key), :before, :after, label, &setting_value(key, &1))
    end)
  end

  defp setting_value(:monthly_report_opt_out, true), do: "Off"
  defp setting_value(:monthly_report_opt_out, false), do: "On"
  defp setting_value(:pack_unseen_retention_days, value) when value in [nil, 0], do: "Off"
  defp setting_value(:pack_unseen_retention_days, value), do: days(value)
  defp setting_value(:runner_inactive_retention_hours, value) when value in [nil, 0], do: "Off"
  defp setting_value(:runner_inactive_retention_hours, value), do: hours(value)
  defp setting_value(:default_role, value), do: role_label(value)
  defp setting_value(:provisioner, value) when value in [:jit, "jit"], do: "On sign-in"
  defp setting_value(:provisioner, value) when value in [:manual, "manual"], do: "Manual"
  defp setting_value(_key, value), do: display_setting(value)

  defp display_setting(nil), do: "Not set"
  defp display_setting(""), do: "Not set"
  defp display_setting(true), do: "On"
  defp display_setting(false), do: "Off"
  defp display_setting(value), do: scalar(value)

  defp role_label(value) do
    case Enum.find(Auth.roles(), &(Atom.to_string(&1) == scalar(value))) do
      nil -> scalar(value)
      role -> Auth.role_label(role)
    end
  end

  defp requirement(true), do: "Required"
  defp requirement(false), do: "Optional"
  defp requirement(_), do: nil

  defp flag(payload, key, label, value) do
    if get(payload, key) == true, do: [{label, value}], else: []
  end

  defp access_changes(payload) do
    before_access = map_value(payload, :before)
    after_access = map_value(payload, :after)

    recorded_change(payload, :before, :after, "Runners", fn access ->
      access |> get(:mode) |> access_mode()
    end) ++
      recorded_change(payload, :before, :after, "Packs", fn access ->
        access |> get(:pack_mode) |> access_mode()
      end) ++
      selection_change(before_access, after_access, :groups, "Groups", :names) ++
      selection_change(before_access, after_access, :runner_ids, "Runners", :counts) ++
      selection_change(before_access, after_access, :pack_ids, "Packs", :names)
  end

  defp access_mode("all"), do: "All"
  defp access_mode("none"), do: "None"
  defp access_mode("restricted"), do: "Selected"
  defp access_mode(value), do: scalar(value)

  defp selection_change(before_access, after_access, key, label, style) do
    case {fetch(before_access, key), fetch(after_access, key)} do
      {{:ok, before_values}, {:ok, after_values}}
      when is_list(before_values) and is_list(after_values) ->
        added = after_values -- before_values
        removed = before_values -- after_values

        cond do
          added == [] and removed == [] ->
            []

          style == :names and length(before_values) <= 3 and length(after_values) <= 3 and
              Enum.all?(before_values ++ after_values, &is_binary/1) ->
            [{label, "#{selection_label(before_values)} → #{selection_label(after_values)}"}]

          true ->
            counts =
              [
                if(added != [], do: "#{length(added)} added"),
                if(removed != [], do: "#{length(removed)} removed")
              ]
              |> Enum.reject(&is_nil/1)
              |> Enum.join(", ")

            [{label, counts}]
        end

      _ ->
        []
    end
  end

  defp selection_label([]), do: "None"
  defp selection_label(values), do: Enum.join(values, ", ")

  defp reporting_runner(p) do
    pairs(
      runner:
        Enum.find(
          [get(p, :runner_name), get(p, :hostname), get(p, :runner_id)],
          &(&1 not in [nil, ""])
        )
    )
  end

  defp key_use(true), do: "Reusable"
  defp key_use(false), do: "Single-use"
  defp key_use(_), do: nil

  defp key_kind(value) when value in [:mcp, "mcp"], do: "AI agent"
  defp key_kind(value) when value in [:audit_export, "audit_export"], do: "Audit export"
  defp key_kind(value), do: scalar(value)

  defp expiration(p) do
    case fetch(p, :expires_at) do
      {:ok, nil} -> [{"Expiration", "No expiration date"}]
      {:ok, value} -> pairs(expires: timestamp(value))
      :error -> []
    end
  end

  defp timestamp(%DateTime{} = value),
    do: Calendar.strftime(value, "%b %-d, %Y, %H:%M UTC")

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> timestamp(datetime)
      _ -> value
    end
  end

  defp timestamp(_), do: nil

  defp draft_operation("draft_saved"), do: "Saved"
  defp draft_operation("draft_discarded"), do: "Discarded"
  defp draft_operation(_), do: nil

  defp decision_label(value) when value in [:approve, "approve"], do: "Approve"
  defp decision_label(value) when value in [:deny, "deny"], do: "Deny"
  defp decision_label(value), do: scalar(value)

  defp approval_tally(p) do
    case {get(p, :approved_count), get(p, :min_approvals)} do
      {count, required} when is_integer(count) and is_integer(required) -> "#{count}/#{required}"
      _ -> nil
    end
  end

  defp grant_duration(value) when value in [:once, "once"], do: "Single use"
  defp grant_duration(value) when value in [:one_hour, "one_hour"], do: "1 hour"
  defp grant_duration(value) when value in [:one_day, "one_day"], do: "1 day"
  defp grant_duration(value) when value in [:thirty_days, "thirty_days"], do: "30 days"
  defp grant_duration(value) when value in [:ninety_days, "ninety_days"], do: "90 days"
  defp grant_duration(value), do: scalar(value)

  defp grant_scope(value) when value in [:exact_args, "exact_args"], do: "Same arguments"
  defp grant_scope(value) when value in [:any_args, "any_args"], do: "Any arguments"
  defp grant_scope(value), do: scalar(value)

  defp cancellation_reason(value)
       when value in [
              "approval expired without decision",
              "Approval expired without decision",
              "Approval expired without a decision."
            ],
       do: "Approval expired."

  defp cancellation_reason(value), do: value

  defp format_version(value) when is_integer(value), do: "v#{value}"
  defp format_version(value), do: scalar(value)

  defp format_duration(ms) when is_integer(ms), do: TimeHelpers.format_duration(ms)
  defp format_duration(_), do: nil

  defp days(value) when is_integer(value) and value > 0, do: format_window(value * 86_400)
  defp days(_), do: nil
  defp hours(value) when is_integer(value) and value > 0, do: format_window(value * 3_600)
  defp hours(_), do: nil

  defp format_window(seconds) when is_integer(seconds) and seconds > 0 do
    {size, unit} =
      Enum.find([{86_400, "day"}, {3_600, "hour"}, {60, "minute"}, {1, "second"}], fn {size, _} ->
        rem(seconds, size) == 0
      end)

    count = div(seconds, size)
    "#{count} #{unit}#{if count == 1, do: "", else: "s"}"
  end

  defp format_window(_), do: nil

  # Fetch, rather than ||, preserves atom-keyed false and explicit null.
  defp fetch(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      :error -> Map.fetch(map, Atom.to_string(key))
      found -> found
    end
  end

  defp fetch(_, _), do: :error

  defp get(map, key) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp map_value(map, key) do
    case get(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp list_value(map, key) do
    case get(map, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp sign_in_method(value) when value in [:magic_link, "magic_link"], do: "magic link"
  defp sign_in_method(value) when value in [:sso, "sso"], do: "SSO"
  defp sign_in_method(value), do: scalar(value)

  defp failure_reason("user.sign_in_failed", value)
       when value in [:invalid_or_expired, "invalid_or_expired"],
       do: "Invalid or expired sign-in code"

  defp failure_reason(_type, value) when value in [:invalid_otp, "invalid_otp"],
    do: "Invalid authenticator code"

  defp failure_reason(_type, value)
       when value in [:invalid_recovery_code, "invalid_recovery_code"],
       do: "Invalid recovery code"

  defp failure_reason(_type, value) when value in [:replay, "replay"], do: "Code already used"

  defp failure_reason(_type, value)
       when value in [:invalid_or_expired, "invalid_or_expired"],
       do: "Invalid or expired code"

  defp failure_reason(type, value)
       when type in [
              "user.email_change_code_failed",
              "user.mfa_enrollment_failed",
              "user.oidc_identity_step_up_failed"
            ] and value in [:invalid, "invalid"],
       do: "Invalid or expired code"

  defp failure_reason(_type, value), do: scalar(value)

  defp confirmation_purpose("link"), do: "Linking SSO"
  defp confirmation_purpose("unlink"), do: "Removing SSO"
  defp confirmation_purpose("verify_provider"), do: "Testing SSO"
  defp confirmation_purpose(value), do: scalar(value)

  defp factor_label(value) when value in [:totp, "totp"], do: "authenticator"
  defp factor_label(value), do: scalar(value)

  defp limit_step("mfa_challenge"), do: "Code verification"
  defp limit_step("mfa_enrollment_issue"), do: "Enrollment code delivery"
  defp limit_step("email_change_issue"), do: "Code delivery"
  defp limit_step("inbox_step_up"), do: "Code verification"
  defp limit_step(_), do: nil

  defp grant_uses(p) do
    case {get(p, :uses_count), get(p, :max_uses)} do
      {count, maximum} when is_integer(count) and is_integer(maximum) -> "#{count}/#{maximum}"
      {count, _} when is_integer(count) -> to_string(count)
      _ -> nil
    end
  end

  defp scope_pairs(p) do
    case get(p, :scope_type) do
      "runner" -> pairs(runner: get(p, :scope_label) || get(p, :scope_value))
      "group" -> pairs(group: get(p, :scope_value))
      _ -> []
    end
  end

  defp version_change(p) do
    case {get(p, :from_version), get(p, :to_version)} do
      {from, to} when is_integer(from) and is_integer(to) and from != to ->
        [{"Version", "v#{from} → v#{to}"}]

      {nil, to} when is_integer(to) ->
        [{"Version", "v#{to}"}]

      _ ->
        []
    end
  end

  defp policy_approval_changes(changes) do
    recorded_change(
      map_value(changes, :min_approvals),
      :from,
      :to,
      "Required approvers",
      &recorded_requirement/1
    ) ++
      recorded_change(
        map_value(changes, :allow_self_approval),
        :from,
        :to,
        "Self-approval",
        &self_approval/1
      )
  end

  defp recorded_requirement(nil), do: "Not recorded"
  defp recorded_requirement(value), do: scalar(value)

  defp self_approval(true), do: "Allowed"
  defp self_approval(false), do: "Not allowed"
  defp self_approval(nil), do: "Not recorded"
  defp self_approval(value), do: scalar(value)

  defp plan_label(value) when value in [:free, "free"], do: "Free"
  defp plan_label(value) when value in [:team, "team"], do: "Team"
  defp plan_label(value) when value in [:enterprise, "enterprise"], do: "Enterprise"
  defp plan_label(value), do: scalar(value)

  defp subscription_status(nil), do: "None"
  defp subscription_status("active"), do: "Active"
  defp subscription_status("trialing"), do: "Trial"
  defp subscription_status("past_due"), do: "Past due"
  defp subscription_status("paused"), do: "Paused"
  defp subscription_status("canceled"), do: "Cancelled"
  defp subscription_status("complimentary"), do: "Complimentary"
  defp subscription_status(value), do: scalar(value)

  defp paid_access(value) when value in [:free, "free"], do: "None"
  defp paid_access(value) when value in [:active, "active", :dunning, "dunning"], do: "Active"
  defp paid_access(value) when value in [:ending, "ending"], do: "Ending"
  defp paid_access(value) when value in [:expired, "expired"], do: "Ended"
  defp paid_access(value) when value in [:unresolved, "unresolved"], do: "Unconfirmed"
  defp paid_access(value), do: scalar(value)

  defp subscribed_plan_change(p) do
    if get(p, :from) == get(p, :from_subscribed_plan) and
         get(p, :to) == get(p, :to_subscribed_plan) do
      []
    else
      recorded_change(
        p,
        :from_subscribed_plan,
        :to_subscribed_plan,
        "Subscription plan",
        &plan_label/1
      )
    end
  end

  defp subscription_schedule(p) do
    case {fetch(p, :from_scheduled_change_action), fetch(p, :to_scheduled_change_action),
          fetch(p, :from_scheduled_change_effective_at),
          fetch(p, :to_scheduled_change_effective_at)} do
      {{:ok, action}, {:ok, action}, {:ok, at}, {:ok, at}} ->
        []

      {{:ok, before_action}, {:ok, nil}, _, _} when not is_nil(before_action) ->
        [{"Scheduled change", "Removed"}]

      {_, {:ok, action}, _, {:ok, at}} when not is_nil(action) ->
        pairs([{schedule_label(action), timestamp(at) || "Scheduled"}])

      _ ->
        # Older receipts saved only the new schedule. Show that fact without
        # claiming when it changed or whether an earlier schedule was removed.
        case get(p, :scheduled_change_action) do
          nil ->
            []

          action ->
            pairs([
              {schedule_label(action),
               timestamp(get(p, :scheduled_change_effective_at)) || "Scheduled"}
            ])
        end
    end
  end

  defp schedule_label("cancel"), do: "Cancellation scheduled"
  defp schedule_label("pause"), do: "Pause scheduled"
  defp schedule_label("resume"), do: "Resume scheduled"
  defp schedule_label(_), do: "Scheduled change"
end
