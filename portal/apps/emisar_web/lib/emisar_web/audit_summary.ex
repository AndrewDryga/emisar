defmodule EmisarWeb.AuditSummary do
  @moduledoc """
  Per-event-type payload summary for the audit log UI. Renders the
  "interesting fact" about an event next to its title so operators
  don't have to open the detail page or read raw JSON to see what
  changed.

  Returns a list of `{label, value}` pairs the LV template renders as
  inline chips, or `[]` when the event type has no notable summary.
  Field lookups tolerate both atom and string keys because audit rows
  go through `Event.Changeset.create/1` which can stamp either shape
  depending on the caller.

  When extending: keep summaries short. A summary that doesn't fit on
  one line is just a worse version of the detail page.
  """

  @doc """
  Returns `[{label, value}, ...]` for the given event. Each value is
  pre-rendered to a string. The LV decides how to style each pair
  (count chip, from→to, plain text, etc.).
  """
  def summary_pairs(%{event_type: type, payload: payload}),
    do: summarize(type, payload || %{})

  # -- Account / membership --------------------------------------------

  defp summarize("account.created", p),
    do: pairs(plan: get(p, :plan), slug: get(p, :slug))

  defp summarize("account.updated", p),
    do: pairs(name: get(p, :name), slug: get(p, :slug))

  defp summarize("account.require_mfa_set", p) do
    case get(p, :require_mfa) do
      true -> [{"MFA", "enforced"}]
      false -> [{"MFA", "off"}]
      _ -> []
    end
  end

  defp summarize("membership.role_changed", p),
    do: from_to(get(p, :from), get(p, :to))

  defp summarize("membership.removed", p),
    do: pairs(role: get(p, :role))

  defp summarize("membership.runner_scopes_changed", p) do
    case get(p, :scope_count) do
      n when is_integer(n) and n > 0 -> [{"scopes", to_string(n)}]
      0 -> [{"scopes", "cleared (all runners)"}]
      _ -> []
    end
  end

  defp summarize("membership.invitation_accepted", p),
    do: pairs(role: get(p, :role))

  defp summarize("user.invitation_accepted", p),
    do: pairs(role: get(p, :role))

  defp summarize("user.invited", p),
    do: pairs(role: get(p, :role))

  # -- Auth / sessions / MFA -------------------------------------------

  defp summarize("user.signed_in", p) do
    case get(p, :method) do
      nil -> []
      m -> [{"via", m}]
    end
  end

  defp summarize("session.account_switched", p),
    do: pairs(role: get(p, :role))

  defp summarize("user.sign_in_failed", p),
    do: pairs(reason: get(p, :reason))

  defp summarize("user.mfa_failed", p),
    do: pairs(reason: get(p, :reason))

  defp summarize("user.mfa_recovery_code_used", p) do
    case get(p, :remaining) do
      n when is_integer(n) -> [{"codes left", to_string(n)}]
      _ -> []
    end
  end

  defp summarize("user.other_sessions_revoked", p) do
    case get(p, :count) do
      n when is_integer(n) and n > 0 -> [{"count", to_string(n)}]
      _ -> []
    end
  end

  defp summarize("user.session_revoked", _p), do: []

  defp summarize("user.email_changed", p),
    do: from_to(get(p, :from), get(p, :to))

  defp summarize("user.profile_updated", p) do
    case get(p, :full_name) do
      nil -> []
      "" -> []
      name -> [{"full name", name}]
    end
  end

  defp summarize("user.updated_by_admin", p) do
    case get(p, :full_name) do
      nil -> []
      name -> [{"full name", name}]
    end
  end

  # -- Runners / auth keys / API keys ----------------------------------

  defp summarize("runner.registered", p),
    do: pairs(group: get(p, :group), hostname: get(p, :hostname))

  defp summarize("runner.disconnected", p),
    do: pairs(reason: get(p, :reason))

  defp summarize("auth_key.created", p) do
    pairs(
      group: get(p, :group),
      reusable: format_bool(get(p, :reusable))
    )
  end

  defp summarize("auth_key.revoked", p),
    do: pairs(prefix: get(p, :prefix))

  defp summarize("auth_key.bound", p) do
    base = pairs(prefix: get(p, :prefix))
    if get(p, :auto), do: base ++ [{"source", "auto-mint"}], else: base
  end

  defp summarize("api_key.created", p) do
    scopes = get(p, :scopes)
    base = pairs(prefix: get(p, :prefix))

    if is_list(scopes) and scopes != [],
      do: base ++ [{"scopes", Enum.join(scopes, ", ")}],
      else: base
  end

  defp summarize("api_key.revoked", p),
    do: pairs(prefix: get(p, :prefix))

  defp summarize("api_key.bound", p) do
    base = pairs(prefix: get(p, :prefix))
    if get(p, :auto), do: base ++ [{"source", "auto-mint"}], else: base
  end

  # -- Runbook ---------------------------------------------------------

  defp summarize("runbook.created", p),
    do: pairs(version: format_version(get(p, :version)))

  defp summarize("runbook.updated", p) do
    from = get(p, :from_version)
    to = get(p, :to_version)

    if is_integer(from) and is_integer(to),
      do: [{"version", "v#{from} → v#{to}"}],
      else: []
  end

  defp summarize("runbook.published", p),
    do: pairs(version: format_version(get(p, :version)))

  # -- Approvals / runs ------------------------------------------------

  defp summarize("approval.approved", p) do
    pairs(
      duration: get(p, :grant_duration),
      scope: get(p, :grant_scope)
    )
  end

  defp summarize("approval.denied", p),
    do: pairs(reason: get(p, :reason))

  defp summarize("approval.grant_used", p) do
    grant =
      case get(p, :grant_id) do
        id when is_binary(id) -> [{"grant", String.slice(id, 0, 8)}]
        _ -> []
      end

    pairs(action: get(p, :action)) ++ grant
  end

  defp summarize("approval.grant_revoked", p) do
    action = get(p, :action_id)
    if action, do: [{"action", action}], else: []
  end

  defp summarize("run.cancel_requested", p),
    do: pairs(action: get(p, :action), reason: get(p, :reason))

  # Run-family rows lead with the bare `action` — the run's identity, rendered
  # unprefixed by the list — followed by that outcome's forensic facts.
  # (Historical rows predate `payload.action`; `pairs/1` just drops the nil.)
  defp summarize("action_run.success", p),
    do: pairs(action: get(p, :action), duration_ms: format_duration(get(p, :duration_ms)))

  defp summarize("action_run.failed", p) do
    pairs(
      action: get(p, :action),
      exit_code: get(p, :exit_code),
      duration_ms: format_duration(get(p, :duration_ms))
    )
  end

  defp summarize("action_run.error", p),
    do: pairs(action: get(p, :action), exit_code: get(p, :exit_code))

  defp summarize("action_run.timed_out", p),
    do: pairs(action: get(p, :action), duration_ms: format_duration(get(p, :duration_ms)))

  defp summarize("action_run.denied", p),
    do: pairs(action: get(p, :action), reason: get(p, :reason))

  defp summarize("action_run.cancelled", p),
    do: pairs(action: get(p, :action), reason: get(p, :reason))

  # The statuses without a special summary (pending_approval, refused, …)
  # still name what was to run.
  defp summarize("action_run." <> _rest, p),
    do: pairs(action: get(p, :action))

  defp summarize("policy.updated", p) do
    # Surface the most interesting bit: how many overrides were
    # touched. The detail page renders the full diff.
    changes = get(p, :changes) || %{}
    overrides = get(changes, :overrides) || %{}
    n_added = length(get(overrides, :added) || [])
    n_removed = length(get(overrides, :removed) || [])
    n_changed = length(get(overrides, :changed) || [])
    defaults_changed = map_size(get(changes, :defaults) || %{})
    from_v = get(p, :from_version)
    to_v = get(p, :to_version)

    version_chunk =
      cond do
        is_integer(from_v) and is_integer(to_v) -> {"version", "v#{from_v} → v#{to_v}"}
        is_integer(to_v) -> {"version", "v#{to_v}"}
        true -> nil
      end

    chunks =
      [
        scope_chunk(p),
        version_chunk,
        defaults_changed > 0 && {"tier defaults", to_string(defaults_changed)},
        n_added > 0 && {"+overrides", to_string(n_added)},
        n_removed > 0 && {"-overrides", to_string(n_removed)},
        n_changed > 0 && {"~overrides", to_string(n_changed)}
      ]
      |> Enum.filter(& &1)

    chunks
  end

  defp summarize("policy.scope_deleted", p),
    do: [scope_chunk(p)] |> Enum.filter(& &1)

  # Catch-all — events without a special summary fall through.
  defp summarize(_type, _payload), do: []

  # -- Helpers ---------------------------------------------------------

  defp from_to(nil, _), do: []
  defp from_to(_, nil), do: []
  defp from_to(from, from), do: []
  defp from_to(from, to), do: [{"change", "#{from} → #{to}"}]

  defp pairs(kw) do
    Enum.flat_map(kw, fn
      {_k, nil} -> []
      {_k, ""} -> []
      {k, v} -> [{to_string(k), to_string(v)}]
    end)
  end

  # Surfaces a runner/group policy override; the account default (the
  # common case) gets no chip so the summary row stays uncluttered. The
  # runner scope_value is the runner id — precise, and the detail page's
  # payload carries it in full.
  defp scope_chunk(p) do
    case get(p, :scope_type) do
      "runner" -> {"scope", "runner: " <> to_string(get(p, :scope_value))}
      "group" -> {"scope", "group: " <> to_string(get(p, :scope_value))}
      _ -> nil
    end
  end

  defp format_bool(true), do: "yes"
  defp format_bool(false), do: "no"
  defp format_bool(_), do: nil

  defp format_version(nil), do: nil
  defp format_version(n) when is_integer(n), do: "v#{n}"
  defp format_version(other), do: to_string(other)

  defp format_duration(nil), do: nil

  defp format_duration(ms) when is_integer(ms) do
    cond do
      ms < 1_000 -> "#{ms}ms"
      ms < 60_000 -> "#{Float.round(ms / 1_000, 1)}s"
      true -> "#{div(ms, 60_000)}m #{div(rem(ms, 60_000), 1_000)}s"
    end
  end

  defp format_duration(_), do: nil

  # Payload values come from `jsonb` — keys are always strings on read.
  # But the test fixtures (and Audit.Multi) stamp atom keys before
  # insert, so the changeset can see either. Accept both.
  defp get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get(_, _), do: nil
end
