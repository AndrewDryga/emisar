defmodule Emisar.Policies do
  @moduledoc """
  Single policy per account. Two-layer model:

    * **risk-tier defaults** — one decision per catalog risk tier
      (`low`/`medium`/`high`/`critical`).
    * **per-action overrides** — ordered list of `{action_glob,
      decision}` pairs that win over the defaults when they match.
      First matching override wins; falls through to the tier default.

  Decisions: `:allow` → runner; `:require_approval` → approval queue;
  `:deny` → blocked. No "allow" rules need to be enumerated — the
  defaults are the policy.

  Stored as JSON in `policies.rules`:

      %{
        "schema_version" => 2,
        "defaults" => %{"low" => "allow", "medium" => "allow",
                        "high" => "require_approval",
                        "critical" => "deny"},
        "overrides" => [
          %{"name" => "allow-cassandra-read", "action" => "cassandra.read_*",
            "decision" => "allow"},
          %{"name" => "block-drop", "action" => "*.drop_*",
            "decision" => "deny"}
        ]
      }
  """

  alias Emisar.{Audit, Auth, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.Policies.{Authorizer, Policy}

  @doc "Whether `subject` may manage policies (admin+)."
  def subject_can_manage_policies?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_policies_permission())

  @risk_tiers ~w(low medium high critical)
  @decisions ~w(allow require_approval deny)

  # Conservative default for a fresh account: low+medium auto-run,
  # high needs approval, critical is blocked outright.
  @default_rules %{
    "schema_version" => 2,
    "defaults" => %{
      "low" => "allow",
      "medium" => "allow",
      "high" => "require_approval",
      "critical" => "deny"
    },
    "overrides" => []
  }

  def default_rules, do: @default_rules
  def risk_tiers, do: @risk_tiers
  def decisions, do: @decisions

  @doc """
  Decisions sit on a permissiveness ladder: allow < require_approval <
  deny. Higher rank = more restrictive. Used both by the changeset
  (to enforce that risk tiers are monotonically restrictive) and by
  the LV (to disable options that would violate the rule).
  """
  def decision_rank("allow"), do: 0
  def decision_rank("require_approval"), do: 1
  def decision_rank("deny"), do: 2
  def decision_rank(_), do: 0

  @doc """
  Changeset for the policy editor form (no Subject — like
  `Accounts.change_user`). Validates the assembled `rules` map so the
  LiveView can render the rules-level error inline; the persisted write
  still goes through `save_rules/2`.
  """
  def change_policy(rules \\ @default_rules), do: Policy.Changeset.form(rules)

  # -- Subject-gated CRUD ---------------------------------------------

  def fetch_policy(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_policies_permission()) do
      Policy.Query.not_deleted()
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Policy.Query)
    end
  end

  @doc """
  Subject-gated save: updates the account's policy rules if one exists,
  or seeds the account's first policy if none does. The LiveView form
  uses this so the same save button works on first save and edit alike.
  """
  def save_rules(rules, %Subject{account: %{id: account_id}, actor: %{id: user_id}} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_policies_permission()
           ) do
      case peek_policy_for_account(account_id) do
        nil ->
          Policy.Changeset.create(%{
            account_id: account_id,
            updated_by_id: user_id,
            rules: rules
          })
          |> Repo.insert()

        %Policy{} = policy ->
          update_rules(policy, rules, subject)
      end
    end
  end

  def update_rules(%Policy{} = policy, rules, %Subject{actor: %{id: user_id}} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_policies_permission()
           ) do
      # `audit:` runs inside the same DB transaction as the update, so a
      # downstream constraint failure rolls back both the policy mutation
      # and its audit row together. The audit changeset closes over the
      # changeset's `data.rules` (pre-update snapshot) and the updated
      # struct's `rules` (post-update) so the diff captures both.
      Policy.Query.not_deleted()
      |> Policy.Query.by_id(policy.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Policy.Query,
        with: &Policy.Changeset.update(&1, %{rules: rules, updated_by_id: user_id}),
        audit: fn updated ->
          before_rules = policy.rules || @default_rules
          after_rules = updated.rules || @default_rules

          Audit.changeset(updated.account_id, "policy.updated",
            actor_kind: "user",
            actor_id: user_id,
            subject_kind: "policy",
            subject_id: updated.id,
            payload: %{
              before: before_rules,
              after: after_rules,
              from_version: policy.vsn,
              to_version: updated.vsn,
              changes: diff_rules(before_rules, after_rules)
            }
          )
        end
      )
    end
  end

  # -- Internal helpers (no Subject needed) ---------------------------

  @doc """
  Internal account-bootstrap helper called from `Accounts.create_account_with_owner/2`
  + seeds + test fixtures. The owner-of-the-new-account is the only one
  who can hit this path; the LV-facing save uses `save_rules/2` and
  goes through the Subject pipeline.
  """
  def seed_policy(account_id, user_id, rules \\ @default_rules) do
    Policy.Changeset.create(%{account_id: account_id, updated_by_id: user_id, rules: rules})
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc """
  Internal default-deny lookup. Returns the policy or `nil` — `nil` is
  the meaningful "no policy configured" signal that `evaluate/3`
  consumes to default-deny every dispatch. Use `fetch_policy/1` (Subject-
  threaded) from LiveView / controllers / MCP — this helper is the
  pre-Subject dispatch fast path.
  """
  def peek_policy_for_account(account_id) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_account_id(account_id)
    |> Repo.peek()
  end

  # -- Evaluation -----------------------------------------------------

  @doc """
  Evaluate the policy for a candidate action. `match_ctx` carries the
  runtime properties (`action_id`, `risk`). Returns
  `{decision, matched_rules, reason}`.
  """
  def evaluate(nil, _match_ctx, _args),
    do: {:deny, [], "no policy configured for this account"}

  def evaluate(%Policy{rules: rules}, %{} = match_ctx, _args) do
    rules = rules || @default_rules
    action_id = match_ctx["action_id"] || ""
    risk = match_ctx["risk"] || "low"

    case find_override(rules["overrides"] || [], action_id) do
      nil ->
        decision = default_for_tier(rules["defaults"] || %{}, risk)
        # The decision is stored separately on the run row and rendered
        # as its own chip; the reason should explain WHY without
        # echoing the verdict.
        {atomize(decision), [], "Default for #{risk}-risk actions"}

      %{"decision" => d} = ov ->
        {atomize(d), [rule_name(ov)], "Override: #{rule_name(ov)}"}
    end
  end

  defp find_override(overrides, action_id) when is_list(overrides),
    do: Enum.find(overrides, &override_matches?(&1, action_id))

  defp override_matches?(%{"action" => pattern}, action_id)
       when is_binary(pattern) and pattern != "",
       do: glob_match?(pattern, action_id)

  defp override_matches?(_, _), do: false

  defp default_for_tier(defaults, tier) when is_map(defaults) do
    case Map.get(defaults, tier) do
      d when d in @decisions -> d
      _ -> "deny"
    end
  end

  defp atomize("allow"), do: :allow
  defp atomize("require_approval"), do: :require_approval
  defp atomize("deny"), do: :deny
  defp atomize(_), do: :deny

  def evaluate_with_policy(account_id, attrs) when is_binary(account_id) do
    policy = peek_policy_for_account(account_id)

    # `evaluate/3` matches on `action_id` (override globs) + `risk` (tier
    # defaults) only. The catalog-authoritative `kind` in `attrs` is the
    # anti-spoofing field carried by `Runs.evaluate_and_dispatch`; the
    # evaluator never reads it, so it isn't threaded into `match_ctx`.
    match_ctx = %{
      "action_id" => attrs[:action_id],
      "risk" => attrs[:risk] || "low"
    }

    {decision, matched, reason} = evaluate(policy, match_ctx, attrs[:args] || %{})
    {decision, matched, reason, policy}
  end

  defp rule_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp rule_name(%{"action" => a}) when is_binary(a), do: a
  defp rule_name(_), do: "unnamed"

  # -- Audit diff ----------------------------------------------------

  @doc false
  def diff_rules(before_rules, after_rules) do
    before_rules = before_rules || @default_rules
    after_rules = after_rules || @default_rules

    %{
      "defaults" =>
        diff_defaults(before_rules["defaults"] || %{}, after_rules["defaults"] || %{}),
      "overrides" =>
        diff_overrides(before_rules["overrides"] || [], after_rules["overrides"] || [])
    }
  end

  # Per-tier diff: %{"high" => %{"from" => "allow", "to" => "require_approval"}, ...}.
  # Tiers that didn't change are omitted so the audit detail can
  # highlight only what moved.
  defp diff_defaults(before_d, after_d) do
    @risk_tiers
    |> Enum.flat_map(fn tier ->
      b = before_d[tier]
      a = after_d[tier]

      if b == a do
        []
      else
        [{tier, %{"from" => b, "to" => a}}]
      end
    end)
    |> Enum.into(%{})
  end

  # Overrides are keyed by `action` for diffing — an override with the
  # same action glob in both lists is the "same" override even if
  # name or decision changed. Yields `%{added: [...], removed: [...],
  # changed: [%{"action" => "x", "from" => %{...}, "to" => %{...}}]}`.
  defp diff_overrides(before_list, after_list) do
    before_map = Map.new(before_list, &{&1["action"], &1})
    after_map = Map.new(after_list, &{&1["action"], &1})

    before_keys = MapSet.new(Map.keys(before_map))
    after_keys = MapSet.new(Map.keys(after_map))

    added =
      after_keys
      |> MapSet.difference(before_keys)
      |> Enum.map(&after_map[&1])

    removed =
      before_keys
      |> MapSet.difference(after_keys)
      |> Enum.map(&before_map[&1])

    changed =
      before_keys
      |> MapSet.intersection(after_keys)
      |> Enum.flat_map(fn action ->
        b = before_map[action]
        a = after_map[action]

        if b == a do
          []
        else
          [%{"action" => action, "from" => b, "to" => a}]
        end
      end)

    %{"added" => added, "removed" => removed, "changed" => changed}
  end

  defp glob_match?(pattern, str) do
    if String.contains?(pattern, "*") do
      escaped = pattern |> Regex.escape() |> String.replace("\\*", ".*")
      regex = Regex.compile!("^" <> escaped <> "$")
      Regex.match?(regex, str)
    else
      pattern == str
    end
  end
end
