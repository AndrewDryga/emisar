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
  alias Ecto.Multi
  alias Emisar.{Analytics, Audit, Auth, Repo}
  alias Emisar.Auth.Subject
  alias Emisar.Policies.{Authorizer, Glob, Policy}

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
    "overrides" => [],
    # GitHub-style approval gate. Defaults reproduce single-approver
    # behavior: one approve dispatches, and the requester may self-approve.
    "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
  }

  def default_rules, do: @default_rules
  def risk_tiers, do: @risk_tiers
  def decisions, do: @decisions

  @doc """
  Distinct-approver threshold from the (already-stored) `rules`. Floors at
  1 — a missing `"approval"` section, a missing key, or any value < 1 reads
  as 1, so rules persisted before this section existed stay single-approver.
  """
  def min_approvals_for(rules) when is_map(rules) do
    case get_in(rules, ["approval", "min_approvals"]) do
      n when is_integer(n) and n >= 1 -> n
      _ -> 1
    end
  end

  def min_approvals_for(_rules), do: 1

  @doc """
  Whether the requester may approve their own run, from the (already-stored)
  `rules`. A MISSING `"approval"` section or key defaults to `true` (legacy
  behavior, before this section existed); a PRESENT key that isn't the boolean
  `true` fails CLOSED (no self-approval) — a corrupt/manually-written value
  must never silently widen the gate. (Matching one level then the key also
  avoids a raise on a non-map `"approval"` section.)
  """
  def self_approval_allowed?(rules) when is_map(rules) do
    case rules do
      %{"approval" => %{"allow_self_approval" => allowed}} -> allowed === true
      _ -> true
    end
  end

  def self_approval_allowed?(_rules), do: true

  @doc """
  Decisions sit on a permissiveness ladder: allow < require_approval <
  deny. Higher rank = more restrictive. Used both by the changeset
  (to enforce that risk tiers are monotonically restrictive) and by
  the LV (to disable options that would violate the rule).
  """
  def decision_rank("allow"), do: 0
  def decision_rank("require_approval"), do: 1
  def decision_rank("deny"), do: 2
  # Unknown decisions rank most-restrictive — fail closed. Reachable
  # only through malformed stored rules (the changeset validates the
  # decision set), and a corrupt tier must read as deny, not allow.
  def decision_rank(_), do: 2

  @doc """
  The shadowed (dead) overrides in `rules`. Overrides are first-match, so an
  override at index `i` is dead when an EARLIER override at index `j < i` has a
  glob whose match-set ⊇ this one's — dispatch always picks `j`, and `i` never
  applies. Returns `[%{index: i, shadowed_by: j}]` reporting the first such `j`.

  Decision-agnostic — any shadowed override is dead code, though a shadowed
  `deny` is the security motivation (the operator believes they blocked an
  action that a broader earlier `allow` actually lets through). Pure (no Subject
  / Repo, like `min_approvals_for/1`); tolerates a missing/empty `"overrides"`
  and skips overrides with a missing/blank `"action"` (they can't meaningfully
  subsume or be subsumed).
  """
  def shadowed_overrides(rules) when is_map(rules) do
    globs = Enum.map(rules["overrides"] || [], &override_action/1)

    for {glob, i} <- Enum.with_index(globs),
        is_binary(glob),
        j = first_subsumer(globs, glob, i),
        not is_nil(j),
        do: %{index: i, shadowed_by: j}
  end

  def shadowed_overrides(_rules), do: []

  # Index of the first earlier override whose glob subsumes `glob` (skipping
  # blank-glob earlier rows, which can't subsume anything), or nil.
  defp first_subsumer(globs, glob, i) do
    globs
    |> Enum.take(i)
    |> Enum.find_index(fn earlier -> is_binary(earlier) and Glob.subsumes?(earlier, glob) end)
  end

  defp override_action(%{"action" => action}) when is_binary(action) and action != "", do: action
  defp override_action(_), do: nil

  @doc """
  Changeset for the policy editor form (no Subject — like
  `Users.change_user`). Validates the assembled `rules` map so the
  LiveView can render the rules-level error inline; the persisted write
  still goes through `save_rules/2`.
  """
  def change_policy(rules \\ @default_rules), do: Policy.Changeset.form(rules)

  # -- Subject-gated CRUD ---------------------------------------------

  def fetch_policy(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_policies_permission()) do
      Policy.Query.not_deleted()
      |> Policy.Query.account_scope()
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Policy.Query)
    end
  end

  @doc """
  Predict the policy decision dispatch would reach for a batch of pending
  targets, so the runbook run plan can mark which steps will pause for
  approval (or be denied) BEFORE the operator presses Start. Each target is
  `%{runner_id, group, action_id, risk}` — the runner's `group` is the
  caller's to supply (from its loaded runner list, exactly as dispatch looks
  it up), keeping Policies out of the Runners table. Requires
  `view_policies`; scopes every policy read to the subject's account. Returns
  `{:ok, %{{runner_id, action_id} => :allow | :require_approval | :deny}}`.

  Mirrors dispatch's `evaluate_with_policy/3` (the
  `resolve_policy` + `evaluate/3` pair `Runs.evaluate_and_dispatch` calls), so
  the prediction matches the real verdict — NOT a re-implementation. The one
  honest gap is dispatch's grant fast-path: a standing grant can let a
  `:require_approval` action run without pausing, which can't be known ahead of
  a specific run, so this reflects the POLICY stance only (the marker is worded
  accordingly).

  Resolves each DISTINCT `(runner_id, group)` policy ONCE and evaluates every
  target against the cached policy in memory — N targets sharing a runner cost
  one policy read, not N.
  """
  def predict_decisions(targets, %Subject{account: %{id: account_id}} = subject)
      when is_list(targets) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_policies_permission()) do
      policies = resolve_policies_for_targets(account_id, targets)

      decisions =
        Map.new(targets, fn %{runner_id: runner_id, action_id: action_id} = target ->
          policy = Map.get(policies, {runner_id, target[:group]})
          match_ctx = %{"action_id" => action_id, "risk" => to_string(target[:risk] || "low")}
          {decision, _matched, _reason} = evaluate(policy, match_ctx, %{})
          {{runner_id, action_id}, decision}
        end)

      {:ok, decisions}
    end
  end

  # One `resolve_policy` read per distinct `(runner_id, group)` — the N+1 guard.
  # `resolve_policy` filters `by_account_id`, so the subject's account scopes
  # the read; the caller already passed the view-policies gate above.
  defp resolve_policies_for_targets(account_id, targets) do
    targets
    |> Enum.map(&{&1.runner_id, &1[:group]})
    |> Enum.uniq()
    |> Map.new(fn {runner_id, group} ->
      {{runner_id, group}, resolve_policy(account_id, runner_id, group)}
    end)
  end

  @doc """
  The account's runner/group policy overrides (every non-account scope),
  newest scope grouping first. The account default is read via
  `fetch_policy/1`; this is the list the editor shows beneath it.
  """
  def list_scoped_policies(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_policies_permission()) do
      results =
        Policy.Query.not_deleted()
        |> Policy.Query.scoped_overrides()
        |> Policy.Query.ordered_by_scope()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, results}
    end
  end

  @doc """
  Fetch one runner/group override by its scope, for the editor. `:not_found`
  when no override exists for that scope yet (the form starts from the
  account default in that case).
  """
  def fetch_scoped_policy(scope_type, scope_value, %Subject{} = subject)
      when scope_type in [:runner, :group] do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_policies_permission()) do
      Policy.Query.not_deleted()
      |> Policy.Query.by_scope(scope_type, scope_value)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Policy.Query)
    end
  end

  @doc """
  Soft-delete a runner/group override: that runner/group falls back to the
  next-broader scope (group, then the account default) on the next dispatch.
  The account default itself isn't deletable through this path.
  """
  def delete_scoped_policy(%Policy{scope_type: scope_type} = policy, %Subject{} = subject)
      when scope_type in [:runner, :group] do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_policies_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, policy.account_id) do
      Multi.new()
      |> Multi.update(:policy, Policy.Changeset.delete(policy))
      |> Multi.insert(:audit, fn %{policy: deleted} ->
        Audit.Events.policy_scope_deleted(subject, deleted)
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{policy: deleted}} -> {:ok, deleted}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Subject-gated save: ONE upsert writes the account's policy whether
  this is the first save or an edit — one policy per account, so the
  partial unique index on `account_id` is the row's identity. The
  conflict update adopts the new rules and bumps `vsn` only when they
  actually changed; the audit diff reads its before-snapshot as a step
  of the same transaction.
  """
  def save_rules(rules, %Subject{} = subject), do: upsert_policy(rules, :account, "", subject)

  @doc """
  Subject-gated save of a runner or group policy override. Upsert keyed on
  `(account, scope)` — first save or edit, one live row per scope. The
  runner_id / group name in `scope_value` is the override's identity;
  dispatch resolution picks it over the account default for that runner/group.
  """
  def save_scoped_rules(rules, scope_type, scope_value, %Subject{} = subject)
      when scope_type in [:runner, :group],
      do: upsert_policy(rules, scope_type, scope_value, subject)

  defp upsert_policy(
         rules,
         scope_type,
         scope_value,
         %Subject{account: %{id: account_id}, actor: %{id: user_id}} = subject
       ) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_policies_permission()
           ) do
      changeset =
        Policy.Changeset.create(%{
          account_id: account_id,
          updated_by_id: user_id,
          rules: rules,
          scope_type: scope_type,
          scope_value: scope_value
        })

      Multi.new()
      |> Multi.run(:before, fn _repo, _changes ->
        {:ok, peek_scoped_policy(account_id, scope_type, scope_value)}
      end)
      |> Multi.insert(:policy, changeset,
        # The conflict target must repeat the partial index's predicate
        # or Postgres won't match the soft-delete-aware unique index.
        on_conflict: Policy.Query.rules_upsert_conflict(),
        conflict_target:
          {:unsafe_fragment, "(account_id, scope_type, scope_value) WHERE deleted_at IS NULL"},
        returning: true
      )
      |> Multi.insert(:audit, fn %{before: before, policy: updated} ->
        # First-ever save of a scope has no before-row; a bare %Policy{}
        # carrying the scope makes the builder diff against the implicit
        # defaults (rules nil → default_rules).
        before = before || %Policy{scope_type: scope_type, scope_value: scope_value}
        Audit.Events.policy_updated(subject, before, updated)
      end)
      |> Repo.commit_multi()
      |> case do
        {:ok, %{policy: policy}} ->
          Analytics.Events.policy_updated(policy, subject)
          {:ok, policy}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # -- Authorization --------------------------------------------------

  @doc "Whether `subject` may manage policies (admin+)."
  def subject_can_manage_policies?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_policies_permission())

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
    |> Policy.Query.account_scope()
    |> Repo.peek()
  end

  @doc """
  Internal — the most specific policy governing a dispatch to `runner_id`
  (in `group`): a policy scoped to that runner, else that group, else the
  account default, else `nil` (no policy → `evaluate/3` default-denies).
  One query fetches the ≤3 candidates; precedence (runner > group > account)
  is resolved in memory. A scoped policy REPLACES the account default for
  that runner/group — it isn't layered on top.

  Security note: `group` is runner-declared (see `Runners.apply_state/2`), so a
  group-scoped override is a SCOPING convenience, not a trust boundary against a
  compromised runner — a host that can forge its group already owns the box the
  runner executes on. The host is the trust anchor; pin `group` to the auth key
  for operator-authoritative scoping. See `docs/security-model.md`.
  """
  def resolve_policy(account_id, runner_id, group) do
    candidates =
      Policy.Query.not_deleted()
      |> Policy.Query.by_account_id(account_id)
      |> Policy.Query.resolvable_for(runner_id, group)
      |> Repo.all()

    Enum.find(candidates, &(&1.scope_type == :runner)) ||
      Enum.find(candidates, &(&1.scope_type == :group)) ||
      Enum.find(candidates, &(&1.scope_type == :account))
  end

  defp peek_scoped_policy(account_id, scope_type, scope_value) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_account_id(account_id)
    |> Policy.Query.by_scope(scope_type, scope_value)
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

      %{"decision" => decision} = override ->
        {atomize(decision), [rule_name(override)], "Override: #{rule_name(override)}"}
    end
  end

  defp find_override(overrides, action_id) when is_list(overrides),
    do: Enum.find(overrides, &override_matches?(&1, action_id))

  defp override_matches?(%{"action" => pattern}, action_id)
       when is_binary(pattern) and pattern != "",
       do: Glob.match?(pattern, action_id)

  defp override_matches?(_, _), do: false

  defp default_for_tier(defaults, tier) when is_map(defaults) do
    case Map.get(defaults, tier) do
      decision when decision in @decisions -> decision
      _ -> "deny"
    end
  end

  defp atomize("allow"), do: :allow
  defp atomize("require_approval"), do: :require_approval
  defp atomize("deny"), do: :deny
  defp atomize(_), do: :deny

  def evaluate_with_policy(account_id, attrs, group) when is_binary(account_id) do
    # Resolve the runner/group override (or the account default) for this
    # dispatch's runner; `group` is the runner's group, looked up by the
    # caller (Runs) so Policies stays out of the Runners table.
    policy = resolve_policy(account_id, attrs[:runner_id], group)

    # `evaluate/3` matches on `action_id` (override globs) + `risk` (tier
    # defaults) only. The catalog-authoritative `kind` in `attrs` is the
    # anti-spoofing field carried by `Runs.evaluate_and_dispatch`; the
    # evaluator never reads it, so it isn't threaded into `match_ctx`.
    # `risk` arrives as the catalog's Ecto.Enum atom; the stored rules
    # key their tier defaults by string, so bridge here.
    match_ctx = %{
      "action_id" => attrs[:action_id],
      "risk" => to_string(attrs[:risk] || "low")
    }

    {decision, matched, reason} = evaluate(policy, match_ctx, attrs[:args] || %{})
    {decision, matched, annotate_scope(reason, policy), policy}
  end

  # Annotate the decision reason with the override scope it came from, so an
  # operator (and the LLM, which shows the reason verbatim) can tell a
  # runner/group override apart from the account-wide policy. Account-scoped
  # and nil policies keep the plain reason.
  defp annotate_scope(reason, %Policy{scope_type: :runner}),
    do: reason <> " — via this runner's policy override"

  defp annotate_scope(reason, %Policy{scope_type: :group, scope_value: group}),
    do: reason <> ~s( — via the "#{group}" group policy override)

  defp annotate_scope(reason, _policy), do: reason

  defp rule_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp rule_name(%{"action" => action}) when is_binary(action), do: action
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
  defp diff_defaults(before_defaults, after_defaults) do
    @risk_tiers
    |> Enum.flat_map(fn tier ->
      before_decision = before_defaults[tier]
      after_decision = after_defaults[tier]

      if before_decision == after_decision do
        []
      else
        [{tier, %{"from" => before_decision, "to" => after_decision}}]
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
        before_override = before_map[action]
        after_override = after_map[action]

        if before_override == after_override do
          []
        else
          [%{"action" => action, "from" => before_override, "to" => after_override}]
        end
      end)

    %{"added" => added, "removed" => removed, "changed" => changed}
  end
end
