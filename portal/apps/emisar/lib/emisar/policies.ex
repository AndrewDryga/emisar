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
  alias Emisar.{Accounts, Audit, Auth, Catalog, Repo, Runners, Users}
  alias Emisar.Auth.Subject
  alias Emisar.Policies.{Authorizer, Glob, Policy, Target}

  @risk_tiers ~w(low medium high critical)
  @decisions ~w(allow require_approval deny)
  @max_min_approvals 2_147_483_647
  # A help summary is bounded independently of the number of targeted policies.
  # This is a read-work bound, never a limit on saved policy configurations.
  @approval_summary_config_limit 100

  # Conservative default for a fresh account: low+medium auto-run,
  # high needs approval, critical is blocked outright.
  #
  # Medium auto-running is a deliberate founder call, raised in two reviews
  # (2026-07-31, 2026-08-04) and affirmed 2026-08-05. Gating medium would put an
  # approval in front of ordinary diagnosis, which is the work operators hand to
  # an agent in the first place — a product that interrupts for every routine
  # read teaches people to approve without reading. The line is drawn at "reads
  # that dump arbitrary secret-bearing state", and that is enforced by TIERING
  # such actions `high` (see packs/AGENTS.md), not by moving this default. An
  # action that leaks secrets at medium is a mis-tiered action; fix its risk.
  @default_rules %{
    "schema_version" => 2,
    "defaults" => %{
      "low" => "allow",
      "medium" => "allow",
      "high" => "require_approval",
      "critical" => "deny"
    },
    "overrides" => [],
    # GitHub-style approval gate. Defaults reproduce single-approver behavior:
    # one approve dispatches, and the requester may self-approve (most accounts
    # have one operator). A team that wants four-eyes turns self-approval OFF in
    # its policy — there is no account-wide flag.
    "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
  }

  @typedoc """
  The editor's working copy of a policy: atom keys outside, the persisted
  string-keyed JSON shapes inside.
  """
  @type approval_input :: %{String.t() => pos_integer() | boolean()}
  @type editor_input :: %{
          defaults: %{String.t() => String.t()},
          overrides: [%{String.t() => String.t()}],
          approval: approval_input()
        }

  @typedoc "One round of operator edits, already parsed out of its transport."
  @type editor_changes :: %{
          optional(:defaults) => %{String.t() => term()},
          optional(:overrides) => [term()],
          optional(:approval) => approval_input()
        }

  def default_rules, do: @default_rules
  def risk_tiers, do: @risk_tiers
  def decisions, do: @decisions
  def max_min_approvals, do: @max_min_approvals

  @doc """
  Returns the complete approval gate stored in `rules`. Missing, extra, or
  malformed values fail closed; callers must not invent runtime defaults after
  the migration that made both settings explicit.
  """
  def approval_settings_for(%{
        "approval" =>
          %{
            "min_approvals" => min_approvals,
            "allow_self_approval" => allow_self_approval
          } = approval
      })
      when map_size(approval) == 2 and is_integer(min_approvals) and min_approvals >= 1 and
             min_approvals <= @max_min_approvals and
             is_boolean(allow_self_approval) do
    {:ok, %{min_approvals: min_approvals, allow_self_approval: allow_self_approval}}
  end

  def approval_settings_for(_rules), do: {:error, :invalid_policy_approval}

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
  / Repo, like `approval_settings_for/1`); tolerates a missing/empty `"overrides"`
  and skips overrides with a missing/blank `"action"` (they can't meaningfully
  subsume or be subsumed).
  """
  def shadowed_overrides(rules) when is_map(rules) do
    globs = Enum.map(overrides_for(rules), &override_action/1)

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

  # -- Policy editor --------------------------------------------------

  @doc """
  The editor's working copy of stored `rules`: a complete tier-default map,
  normalized override rows, and a complete approval gate.

  Valid values are preserved; a missing or unknown tier/override decision reads
  as `"deny"`, the verdict runtime evaluation already reaches for a corrupt one.
  The approval gate is the stored one: every row has carried a complete gate
  since the backfill migration, and the changeset refuses anything else on save,
  so a row without one is a broken invariant, not an editor state.
  """
  @spec editor_input(term()) :: editor_input()
  def editor_input(rules) do
    %{
      defaults: rules |> defaults_for() |> normalize_defaults() |> enforce_monotonic(),
      overrides: Enum.map(overrides_for(rules), &normalize_override/1),
      approval: approval_input(rules)
    }
  end

  @doc """
  Apply one round of operator edits to `input`. `changes` is domain-shaped: a
  partial `%{tier => decision}` map, an override list ordered like the current
  rows, and an already-parsed approval gate — the transport layer owns form
  strings and indexed maps.

  An unknown decision or a non-string name/action keeps the current value, rows
  past the server-owned ones are ignored, and the tiers are re-lifted to
  low→critical monotonic restrictiveness so the operator never holds a
  combination the changeset rejects.
  """
  @spec update_editor_input(editor_input(), editor_changes()) :: editor_input()
  def update_editor_input(input, changes) do
    defaults = input.defaults |> merge_defaults(changes[:defaults]) |> enforce_monotonic()

    %{
      defaults: defaults,
      overrides: merge_overrides(input.overrides, changes[:overrides]),
      approval: merge_approval(input.approval, changes[:approval])
    }
  end

  @doc """
  A fresh override row for the editor's add affordance. An intentional new row
  starts at `allow`; only a corrupt STORED decision repairs to `deny`.
  """
  @spec empty_override() :: %{String.t() => String.t()}
  def empty_override, do: %{"name" => "", "action" => "", "decision" => "allow"}

  @doc """
  The canonical schema-v2 rules an editor authors: the tier defaults and
  approval gate as-is, overrides in order with their name/action trimmed and
  blank-action rows dropped.

  Authoring construction only — `save_rules/2`, dispatch, and the changeset
  still take the rules a caller hands them, so no save path silently normalizes
  arbitrary input.
  """
  @spec build_rules(editor_input()) :: map()
  def build_rules(%{defaults: defaults, overrides: overrides, approval: approval}) do
    authored = overrides |> Enum.map(&authored_override/1) |> Enum.reject(&blank_action?/1)

    %{
      "schema_version" => 2,
      "defaults" => defaults,
      "overrides" => authored,
      "approval" => approval
    }
  end

  defp approval_input(rules) do
    {:ok, approval} = approval_settings_for(rules)

    %{
      "min_approvals" => approval.min_approvals,
      "allow_self_approval" => approval.allow_self_approval
    }
  end

  defp normalize_defaults(defaults),
    do: Map.new(@risk_tiers, fn tier -> {tier, normalize_decision(defaults[tier])} end)

  defp normalize_override(override) when is_map(override) do
    %{
      "name" => override_text(override["name"]),
      "action" => override["action"] |> override_text() |> String.trim(),
      "decision" => normalize_decision(override["decision"])
    }
  end

  defp override_text(value) when is_binary(value), do: value
  defp override_text(_value), do: ""

  defp merge_defaults(defaults, changes) when is_map(changes) do
    Map.new(@risk_tiers, fn tier -> {tier, posted_decision(changes[tier], defaults[tier])} end)
  end

  defp merge_defaults(defaults, _changes), do: defaults

  # Walk low→critical, lifting any tier more permissive than its predecessor to
  # the predecessor's rank — so setting `low` to deny bumps the rest, and the
  # operator never sees a transient state the server would reject. A decision's
  # position in @decisions IS its `decision_rank/1`, so the ladder has one source.
  defp enforce_monotonic(defaults) do
    @risk_tiers
    |> Enum.reduce({defaults, 0}, fn tier, {acc, floor_rank} ->
      rank = max(decision_rank(acc[tier]), floor_rank)
      {Map.put(acc, tier, Enum.at(@decisions, rank)), rank}
    end)
    |> elem(0)
  end

  # Rows are server-owned: a posted list longer than the current one is ignored,
  # so a crafted event can't append an override nobody added.
  defp merge_overrides(overrides, changes) when is_list(changes) do
    overrides
    |> Enum.with_index()
    |> Enum.map(fn {override, index} -> merge_override(override, Enum.at(changes, index)) end)
  end

  defp merge_overrides(overrides, _changes), do: overrides

  defp merge_approval(current, approval) do
    case approval_settings_for(%{"approval" => approval}) do
      {:ok, parsed} ->
        %{
          "min_approvals" => parsed.min_approvals,
          "allow_self_approval" => parsed.allow_self_approval
        }

      {:error, :invalid_policy_approval} ->
        current
    end
  end

  defp merge_override(override, change) when is_map(change) do
    %{
      "name" => posted_text(change["name"], override["name"]),
      "action" => posted_text(change["action"], override["action"]),
      "decision" => posted_decision(change["decision"], override["decision"])
    }
  end

  defp merge_override(override, _change), do: override

  defp posted_text(posted, _current) when is_binary(posted), do: posted
  defp posted_text(_posted, current), do: current

  defp posted_decision(posted, _current) when posted in @decisions, do: posted
  defp posted_decision(_posted, current), do: normalize_decision(current)

  defp authored_override(override) do
    %{
      "name" => trimmed(override["name"]),
      "action" => trimmed(override["action"]),
      "decision" => override["decision"]
    }
  end

  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(_value), do: ""

  defp blank_action?(%{"action" => ""}), do: true
  defp blank_action?(_override), do: false

  @doc """
  Changeset for the policy editor form (no Subject — like
  `Users.change_user`). Validates the assembled `rules` map so the
  LiveView can render the rules-level error inline; the persisted write
  still goes through `save_rules/2`.
  """
  def change_policy(rules \\ @default_rules), do: Policy.Changeset.form(rules)

  # -- Subject-gated CRUD ---------------------------------------------

  def fetch_policy(%Subject{} = subject) do
    with {:ok, subject} <-
           Auth.fetch_current_subject(Authorizer.view_policies_permission(), subject) do
      Policy.Query.not_deleted()
      |> Policy.Query.account_scope()
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Policy.Query)
    end
  end

  @doc """
  Summarizes current approval settings in the account default and saved
  runner/group rulesets. Existing requests retain their saved requirements.

  Returns a common approver count (or `:varies`) and whether self-approval is
  uniformly allowed, forbidden, or varies. Missing/invalid settings and an
  oversized set of distinct configurations return an error, not assumed defaults.
  """
  def fetch_approval_requirements_summary(%Subject{} = subject) do
    with {:ok, policy} <- fetch_policy(subject),
         {:ok, default} <- approval_settings_for(policy.rules),
         {:ok, scoped} <- scoped_approval_settings(subject) do
      settings = [default | scoped]

      {:ok,
       %{
         min_approvals: common_approval_setting(settings, :min_approvals),
         allow_self_approval: common_approval_setting(settings, :allow_self_approval)
       }}
    end
  end

  defp scoped_approval_settings(subject) do
    rules =
      Policy.Query.not_deleted()
      |> Policy.Query.scoped_overrides()
      |> Policy.Query.distinct_approval_rules(@approval_summary_config_limit + 1)
      |> Authorizer.for_subject(subject)
      |> Repo.all()

    validate_summary_settings(rules)
  end

  defp validate_summary_settings(rules) when length(rules) > @approval_summary_config_limit,
    do: {:error, :approval_summary_too_complex}

  defp validate_summary_settings(rules) do
    Enum.reduce_while(rules, {:ok, []}, fn rules, {:ok, settings} ->
      case approval_settings_for(rules) do
        {:ok, setting} -> {:cont, {:ok, [setting | settings]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp common_approval_setting(settings, field) do
    values = settings |> Enum.map(&Map.fetch!(&1, field)) |> Enum.uniq()

    case values do
      [value] -> value
      _values -> :varies
    end
  end

  @doc """
  Internal — snapshot the exact policy facts for one bounded runbook plan in
  one policy read. The caller already owns authorization for the targets; this
  helper is deliberately limited to execution preflight and creation rechecks.
  """
  def snapshot_runbook_decisions(account_id, targets)
      when is_binary(account_id) and is_list(targets) do
    runner_ids = targets |> Enum.map(& &1.runner_id) |> Enum.uniq()
    groups = targets |> Enum.map(& &1.runner_group) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    policies =
      Policy.Query.not_deleted()
      |> Policy.Query.by_account_id(account_id)
      |> Policy.Query.resolvable_for_many(runner_ids, groups)
      |> Repo.all()

    Enum.map(targets, &snapshot_runbook_decision(&1, policies))
  end

  defp snapshot_runbook_decision(target, policies) do
    policy =
      Enum.find(
        policies,
        &(&1.scope_type == :runner and &1.scope_value == to_string(target.runner_id))
      ) ||
        Enum.find(
          policies,
          &(&1.scope_type == :group and &1.scope_value == target.runner_group)
        ) ||
        Enum.find(policies, &(&1.scope_type == :account))

    match_ctx = %{
      "action_id" => target.action_id,
      "risk" => to_string(target[:risk] || "low")
    }

    {decision, matched, reason} = evaluate(policy, match_ctx)

    %{
      decision: decision,
      matched_rules: matched,
      reason: reason,
      policy: policy,
      approval: approval_snapshot(decision, policy)
    }
  end

  defp approval_snapshot(:require_approval, %Policy{rules: rules}) do
    case approval_settings_for(rules) do
      {:ok, settings} -> settings
      {:error, :invalid_policy_approval} -> :invalid
    end
  end

  defp approval_snapshot(_decision, _policy), do: nil

  @doc "Lists a bounded page of saved account targets, without policy rules."
  def list_scoped_policy_summaries(%Subject{} = subject, opts \\ []) do
    with {:ok, subject} <-
           Auth.fetch_current_subject(Authorizer.view_policies_permission(), subject),
         {:ok, summaries, metadata} <- scoped_summary_page(subject, opts) do
      summaries =
        Enum.map(summaries, fn summary ->
          %{summary | scope_type: if(summary.scope_type == "runner", do: :runner, else: :group)}
        end)

      ids = for %{scope_type: :runner, scope_value: id} <- summaries, Repo.valid_uuid?(id), do: id
      labels = Runners.current_runner_labels_for_ids(subject.account.id, ids)

      summaries =
        Enum.map(summaries, fn summary ->
          label =
            if summary.scope_type == :runner,
              do: Map.get(labels, summary.scope_value, summary.scope_value),
              else: summary.scope_value

          Map.put(summary, :target_label, label)
        end)

      {:ok, summaries, metadata}
    end
  end

  defp scoped_summary_page(subject, opts) do
    Policy.Query.not_deleted()
    |> Policy.Query.scoped_overrides()
    |> Policy.Query.select_summary()
    |> Authorizer.for_subject(subject)
    |> Repo.list(Policy.Query, bounded_page(opts, 25, :auto))
  end

  @doc "Loads one saved editor; foreign and deleted rows are not found."
  def fetch_scoped_policy_by_id(id, %Subject{} = subject) do
    with {:ok, subject} <-
           Auth.fetch_current_subject(Authorizer.view_policies_permission(), subject),
         true <- Repo.valid_uuid?(id) do
      Policy.Query.not_deleted()
      |> Policy.Query.scoped_overrides()
      |> Policy.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Policy.Query)
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  A bounded, searchable target page, including globally taken targets.

  Returns `{:error, :invalid_search}` for malformed UTF-8, null characters or
  search terms longer than 512 bytes.
  """
  def list_scope_target_options(search, %Subject{} = subject, opts \\ []) do
    with {:ok, subject} <-
           Auth.fetch_current_subject(Authorizer.view_policies_permission(), subject),
         {:ok, search} <- target_search(search) do
      target_query(subject)
      |> Target.Query.with_policy()
      |> Target.Query.search(search)
      |> Authorizer.for_subject(subject)
      |> Repo.list(Target.Query, bounded_page(opts, 25, false))
    end
  end

  defp target_search(search) when is_binary(search) and byte_size(search) <= 512 do
    if String.valid?(search) and not String.contains?(search, <<0>>),
      do: {:ok, String.trim(search)},
      else: {:error, :invalid_search}
  end

  defp target_search(_search), do: {:error, :invalid_search}

  @doc "Resolves a selected target independently of its current search page."
  def fetch_scope_target_option(scope_type, scope_value, %Subject{} = subject)
      when scope_type in [:runner, :group] and is_binary(scope_value) do
    with {:ok, subject} <-
           Auth.fetch_current_subject(Authorizer.view_policies_permission(), subject) do
      target_query(subject)
      |> Target.Query.by_scope(scope_type, scope_value)
      |> Target.Query.with_policy()
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Target.Query)
    end
  end

  @doc "Whether any reachable target remains after saved policies and all open drafts."
  def scope_target_available?(reserved, %Subject{} = subject) when is_list(reserved) do
    with {:ok, subject} <-
           Auth.fetch_current_subject(Authorizer.view_policies_permission(), subject) do
      available? =
        target_query(subject)
        |> Target.Query.with_policy()
        |> Target.Query.available(reserved)
        |> Authorizer.for_subject(subject)
        |> Repo.exists?()

      {:ok, available?}
    end
  end

  defp target_query(subject) do
    subject.account.id
    |> Runners.scope_targets_query(Accounts.runner_access_for_subject(subject))
    |> Target.Query.all()
  end

  defp bounded_page(opts, limit, count) do
    page = Keyword.get(opts, :page, [])
    page = Keyword.put(page, :limit, min(Keyword.get(page, :limit, limit), limit))
    opts |> Keyword.put(:page, page) |> Keyword.put(:count, count)
  end

  @doc """
  Soft-delete a runner/group override: that runner/group falls back to the
  next-broader scope (group, then the account default) on the next dispatch.
  The account default itself isn't deletable through this path. Removing a
  ruleset changes what may run on its hosts, so the subject needs CURRENT full
  pack access and the target is re-judged against their CURRENT runner access —
  an open page whose access has since narrowed cannot spend the row it still
  holds.
  """
  def delete_scoped_policy(%Policy{} = policy, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_policies_permission()
           ) do
      Multi.new()
      |> Multi.run(:active_account, fn repo, _changes ->
        Accounts.fetch_and_lock_account(subject.account.id, repo: repo)
      end)
      |> Multi.run(:access, fn repo, _changes ->
        fetch_and_lock_policy_access(repo, subject)
      end)
      # Judge scope on the LOCKED, subject-scoped row, not the caller's struct:
      # a foreign policy scopes out to :not_found, and a member whose runner
      # access has since narrowed can no longer spend a row they still hold.
      |> Multi.run(:loaded_policy, fn repo, %{access: access} ->
        query =
          Policy.Query.not_deleted()
          |> Policy.Query.scoped_overrides()
          |> Policy.Query.by_id(policy.id)
          |> Policy.Query.lock_for_update()
          |> Authorizer.for_subject(subject)

        with {:ok, loaded_policy} <- repo.fetch(query, Policy.Query),
             :ok <- ensure_policy_access(loaded_policy.scope_type, access),
             :ok <-
               ensure_policy_removal_target(
                 loaded_policy,
                 subject.account.id,
                 access,
                 repo
               ) do
          {:ok, loaded_policy}
        end
      end)
      |> Multi.update(:policy, fn %{loaded_policy: loaded_policy} ->
        Policy.Changeset.delete(loaded_policy)
      end)
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
  of the same transaction. Because this default governs every runner and its
  rules match actions from every pack, the writer needs CURRENT full runner and
  pack access.
  """
  def save_rules(rules, %Subject{} = subject), do: upsert_policy(rules, :account, "", subject)

  @doc """
  Subject-gated save of a runner or group policy override. Upsert keyed on
  `(account, scope)` — first save or edit, one live row per scope. The
  runner_id / group name in `scope_value` is the override's identity;
  dispatch resolution picks it over the account default for that runner/group.

  The scope must be one the subject's own runner access reaches:
  `{:error, :runner_not_found}` for a runner that is foreign, deleted, malformed,
  or outside their fleet. A `:group` scope is a name rather than a host, so an
  UNRESTRICTED subject may name any group — including one nothing is enrolled in
  yet, so a ruleset can be prepared before the hosts join it — while a narrowed
  subject gets `{:error, :group_not_found}` for any group outside their reach,
  known or not.

  Policy rules match action ids and risk tiers rather than pack ids, so the
  writer also needs CURRENT full pack access.
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
           ),
         :ok <- ensure_policy_mutation_access(scope_type, subject),
         :ok <- ensure_policy_target_shape(scope_type, scope_value) do
      changeset =
        Policy.Changeset.create(%{
          account_id: account_id,
          updated_by_id: user_id,
          rules: rules,
          scope_type: scope_type,
          scope_value: scope_value
        })

      Multi.new()
      |> Multi.run(:active_account, fn repo, _changes ->
        Accounts.fetch_and_lock_account(account_id, repo: repo)
      end)
      |> Multi.run(:access, fn repo, _changes ->
        with {:ok, access} <- fetch_and_lock_policy_access(repo, subject),
             :ok <- ensure_policy_access(scope_type, access),
             :ok <-
               ensure_and_lock_policy_target(scope_type, scope_value, account_id, access, repo) do
          {:ok, access}
        end
      end)
      |> Multi.run(:before, fn repo, _changes ->
        {:ok, peek_scoped_policy(repo, account_id, scope_type, scope_value)}
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
        {:ok, %{policy: policy}} -> {:ok, policy}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -- Authorization --------------------------------------------------

  @doc "True when the subject may view the policy (the console nav + section gate)."
  def subject_can_view_policies?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.view_policies_permission())

  @doc "Whether `subject` holds the policy-management permission; reach-aware predicates decide which editors they may change."
  def subject_can_manage_policies?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_policies_permission())

  @doc """
  Current policy-editor capabilities, including hints for concrete runner/group
  targets. Queries are batched; saved policies and their previews stay readable
  outside action access. These hints never replace mutation authorization.
  """
  def policy_management_capabilities(%Subject{} = subject, targets \\ []) do
    case Auth.fetch_current_subject(Authorizer.view_policies_permission(), subject) do
      {:ok, subject} ->
        access = Accounts.runner_access_for_subject(subject)
        capabilities = policy_capabilities(subject_can_manage_policies?(subject), access)

        Map.put(
          capabilities,
          :targets,
          policy_target_capabilities(targets, capabilities, subject.account.id, access)
        )

      {:error, _reason} ->
        policy_capabilities(false, Accounts.RunnerAccess.none())
        |> Map.put(:targets, Map.new(targets, &{&1, false}))
    end
  end

  defp policy_target_capabilities(targets, %{can_manage_scoped?: false}, _account_id, _access),
    do: Map.new(targets, &{&1, false})

  defp policy_target_capabilities(targets, _capabilities, account_id, access) do
    {granted_groups, remaining} =
      targets
      |> Enum.uniq()
      |> Enum.split_with(fn
        {:group, group} when is_binary(group) and group != "" ->
          access.mode == :all or group in access.groups

        _ ->
          false
      end)

    allowed =
      remaining
      |> Enum.chunk_every(100)
      |> Enum.flat_map(fn batch ->
        account_id
        |> Runners.scope_targets_query(access)
        |> Target.Query.all()
        |> Target.Query.by_scopes(batch)
        |> Target.Query.select_scope_identity()
        |> Repo.all()
        |> Enum.map(fn {type, value} ->
          {if(type == "runner", do: :runner, else: :group), value}
        end)
      end)
      |> Enum.concat(granted_groups)
      |> MapSet.new()

    Map.new(targets, &{&1, MapSet.member?(allowed, &1)})
  end

  defp policy_capabilities(can_manage?, access) do
    has_runner_access? = access.mode != :none
    has_all_runner_access? = access.mode == :all
    has_all_pack_access? = access.pack_mode == :all

    %{
      can_manage?: can_manage?,
      has_runner_access?: has_runner_access?,
      can_manage_scoped?: can_manage? and has_runner_access? and has_all_pack_access?,
      can_manage_account?: can_manage? and has_all_runner_access? and has_all_pack_access?
    }
  end

  @doc "Whether `subject` may change a runner/group policy in their current reach."
  def subject_can_manage_scoped_policies?(%Subject{} = subject),
    do: policy_management_capabilities(subject).can_manage_scoped?

  @doc "Whether `subject` may change the account default that governs every runner and pack."
  def subject_can_manage_account_policy?(%Subject{} = subject),
    do: policy_management_capabilities(subject).can_manage_account?

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
  Internal — the account-default (account-scoped) policy row, or `nil`
  when none is configured. Read by the seeds + test fixtures to bootstrap
  or inspect the default; the dispatch path resolves the governing policy
  via `resolve_policy/3`, and LiveView / controllers / MCP read the
  default through the Subject-threaded `fetch_policy/1`.
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
  account default, else `nil` (no policy → `evaluate/2` default-denies).
  One query fetches the ≤3 candidates; precedence (runner > group > account)
  is resolved in memory. A scoped policy REPLACES the account default for
  that runner/group — it isn't layered on top.

  Security note: `group` is runner-declared (see `Runners.apply_state/2`), so a
  group-scoped override is a SCOPING convenience, not a trust boundary against a
  compromised runner — a host that can forge its group already owns the box the
  runner executes on. The host is the trust anchor; pin `group` to the enrollment key
  for operator-authoritative scoping. See `.agent/kb/specs/security-model.md`.
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

  defp peek_scoped_policy(repo, account_id, scope_type, scope_value) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_account_id(account_id)
    |> Policy.Query.by_scope(scope_type, scope_value)
    |> repo.peek()
  end

  # Policy rules match risk tiers and action globs, not pack ids, so every write
  # needs the whole pack dimension. The account default also governs every
  # runner; a targeted override stays confined by the reach check below.
  defp ensure_policy_mutation_access(:account, %Subject{} = subject) do
    ensure_policy_access(:account, Accounts.runner_access_for_subject(subject))
  end

  defp ensure_policy_mutation_access(scope_type, %Subject{} = subject)
       when scope_type in [:runner, :group] do
    ensure_policy_access(scope_type, Accounts.runner_access_for_subject(subject))
  end

  defp fetch_and_lock_policy_access(repo, %Subject{actor: %Users.User{id: user_id}} = subject) do
    with {:ok, membership} <-
           Accounts.fetch_and_lock_membership(subject.account.id, subject.membership_id,
             repo: repo
           ),
         true <- membership.user_id == user_id,
         {:ok, _user} <- Users.fetch_and_lock_user_by_id(user_id, repo),
         {:ok, _subject} <-
           Auth.fetch_current_subject(Authorizer.manage_policies_permission(), subject) do
      {:ok, Accounts.runner_access_for_locked_membership(repo, membership)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp fetch_and_lock_policy_access(_repo, _subject), do: {:error, :unauthorized}

  defp ensure_policy_access(:account, %Accounts.RunnerAccess{mode: :all, pack_mode: :all}),
    do: :ok

  defp ensure_policy_access(scope_type, %Accounts.RunnerAccess{pack_mode: :all})
       when scope_type in [:runner, :group],
       do: :ok

  defp ensure_policy_access(_scope_type, _access), do: {:error, :unauthorized}

  defp ensure_policy_target_shape(:account, _value), do: :ok

  defp ensure_policy_target_shape(:runner, value) do
    if Repo.valid_uuid?(value), do: :ok, else: {:error, :runner_not_found}
  end

  defp ensure_policy_target_shape(:group, value) when is_binary(value) and value != "", do: :ok
  defp ensure_policy_target_shape(:group, _value), do: {:error, :group_not_found}

  # An unrestricted manager may remove a dangling override after its runner was
  # deleted. The account-scoped policy and current all-pack gate are already checked.
  defp ensure_policy_removal_target(_policy, _account_id, %{mode: :all}, _repo), do: :ok

  defp ensure_policy_removal_target(policy, account_id, access, repo) do
    ensure_and_lock_policy_target(
      policy.scope_type,
      policy.scope_value,
      account_id,
      access,
      repo
    )
  end

  defp ensure_and_lock_policy_target(:account, _value, _account_id, _access, _repo), do: :ok

  defp ensure_and_lock_policy_target(:runner, id, account_id, access, repo) do
    with {:ok, [runner]} <-
           Runners.fetch_and_lock_cancellation_runners(account_id, [id], repo: repo),
         true <- Accounts.RunnerAccess.runner_in_scope?(runner, access) do
      :ok
    else
      false -> {:error, :unauthorized}
      {:error, _reason} -> {:error, :runner_not_found}
    end
  end

  defp ensure_and_lock_policy_target(:group, "", _account_id, _access, _repo),
    do: {:error, :group_not_found}

  defp ensure_and_lock_policy_target(:group, group, account_id, access, repo) do
    case Runners.ensure_group_access(account_id, [group], access, repo: repo) do
      :ok ->
        :ok

      {:error, _reason} ->
        if known_scope_target?(:group, group, account_id) or saved_group?(group, account_id),
          do: {:error, :unauthorized},
          else: {:error, :group_not_found}
    end
  end

  defp known_scope_target?(type, value, account_id) do
    account_id
    |> Runners.scope_targets_query(Accounts.RunnerAccess.all())
    |> Target.Query.all()
    |> Target.Query.by_scope(type, value)
    |> Repo.exists?()
  end

  defp saved_group?(group, account_id) do
    Policy.Query.not_deleted()
    |> Policy.Query.by_account_id(account_id)
    |> Policy.Query.by_scope(:group, group)
    |> Repo.exists?()
  end

  @doc "Computes a policy preview in bounded, freshly authorized catalog batches."
  def preview_policy(input, editor_ref, %Subject{} = subject, opts \\ []) do
    with {:ok, subject} <-
           Auth.fetch_current_subject(Authorizer.view_policies_permission(), subject),
         :ok <- validate_preview_input(input),
         {:ok, target} <- preview_target(editor_ref, subject) do
      rules = build_rules(input)

      matchers =
        for {row, index} <- Enum.with_index(input.overrides),
            pattern = String.trim(row["action"] || ""),
            pattern != "",
            do: {index, Glob.compile(pattern)}

      state = %{
        total: 0,
        account_id: subject.account.id,
        editor_ref: editor_ref,
        target: target,
        outcome: empty_outcome(),
        breakdown: Map.new(@risk_tiers, &{&1, 0}),
        unmatched_override_indexes: MapSet.new(matchers, &elem(&1, 0))
      }

      plan = %{
        target: target,
        editor_ref: editor_ref,
        defaults: defaults_for(rules),
        overrides: compile_overrides(overrides_for(rules)),
        matchers: matchers,
        cancelled?: Keyword.get(opts, :cancelled?, fn -> false end)
      }

      preview_batches(plan, subject, state, nil)
    end
  end

  @doc "Rechecks a completed background preview immediately before the web adapter publishes it."
  def preview_current?(
        %{account_id: account_id, editor_ref: ref, target: target},
        %Subject{} = subject
      ) do
    with true <- account_id == subject.account.id,
         {:ok, subject} <-
           Auth.fetch_current_subject(Authorizer.view_policies_permission(), subject) do
      preview_target(ref, subject) == {:ok, target}
    else
      _ -> false
    end
  end

  defp validate_preview_input(%{overrides: overrides} = input)
       when is_list(overrides) and length(overrides) <= 200 do
    if Enum.all?(overrides, fn row ->
         is_map(row) and is_binary(row["action"]) and String.length(row["action"]) <= 200
       end) and
         change_policy(build_rules(input)).valid?, do: :ok, else: {:error, :invalid_rules}
  end

  defp validate_preview_input(_), do: {:error, :invalid_rules}

  defp preview_target(:account, _subject), do: {:ok, :account}

  defp preview_target(id, subject) when is_binary(id) do
    if Repo.valid_uuid?(id) do
      Policy.Query.not_deleted()
      |> Policy.Query.scoped_overrides()
      |> Policy.Query.by_id(id)
      |> Policy.Query.select_scope()
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Policy.Query)
      |> case do
        {:ok, policy} -> {:ok, {policy.scope_type, policy.scope_value}}
        error -> error
      end
    else
      {:error, :not_found}
    end
  end

  defp preview_target({type, value}, subject)
       when type in [:runner, :group] and is_binary(value) do
    if known_scope_target?(type, value, subject.account.id) or
         preview_empty_group?(type, value, subject),
       do: {:ok, {type, value}},
       else: {:error, :not_found}
  end

  defp preview_target(_, _subject), do: {:error, :not_found}

  defp preview_empty_group?(:group, group, subject) when group != "" do
    access = Accounts.runner_access_for_subject(subject)
    access.mode == :all or group in access.groups or saved_group?(group, subject.account.id)
  end

  defp preview_empty_group?(_type, _value, _subject), do: false

  defp preview_batches(plan, subject, state, cursor) do
    with :ok <- preview_continues(plan, subject),
         {:ok, actions, metadata} <-
           Catalog.list_action_risks(plan.target, subject, page: [limit: 100, cursor: cursor]),
         :ok <- preview_continues(plan, subject) do
      state =
        Enum.reduce(actions, state, fn %{action_id: id, risk: risk}, state ->
          unmatched =
            Enum.reduce(plan.matchers, state.unmatched_override_indexes, fn {index, matcher},
                                                                            unmatched ->
              if MapSet.member?(unmatched, index) and Glob.match_compiled?(matcher, id),
                do: MapSet.delete(unmatched, index),
                else: unmatched
            end)

          %{
            state
            | total: state.total + 1,
              outcome:
                add_outcome_action(
                  state.outcome,
                  simulation_decision(plan.defaults, plan.overrides, id, risk),
                  id
                ),
              breakdown: Map.update!(state.breakdown, risk, &(&1 + 1)),
              unmatched_override_indexes: unmatched
          }
        end)

      cond do
        metadata.next_page_cursor ->
          preview_batches(plan, subject, state, metadata.next_page_cursor)

        state.total == 0 ->
          {:ok, %{state | unmatched_override_indexes: MapSet.new()}}

        true ->
          {:ok, state}
      end
    end
  end

  defp preview_continues(plan, subject) do
    with false <- plan.cancelled?.(),
         {:ok, subject} <-
           Auth.fetch_current_subject(Authorizer.view_policies_permission(), subject),
         {:ok, target} when target == plan.target <- preview_target(plan.editor_ref, subject) do
      :ok
    else
      true -> {:error, :cancelled}
      _ -> {:error, :unauthorized}
    end
  end

  # -- Evaluation -----------------------------------------------------

  @doc """
  Evaluate the policy for a candidate action. `match_ctx` carries the
  runtime properties (`action_id`, `risk`). Returns
  `{decision, matched_rules, reason}`.
  """
  def evaluate(nil, _match_ctx),
    do: {:deny, [], "No policy is configured for this account, so this action was denied."}

  def evaluate(%Policy{rules: rules} = policy, %{} = match_ctx) do
    action_id = match_ctx["action_id"] || ""
    risk = normalize_risk(match_ctx["risk"])
    overrides = compile_overrides(overrides_for(rules))

    case find_compiled_override(overrides, action_id) do
      nil ->
        decision = default_for_tier(defaults_for(rules), risk)
        decision = atomize(decision)
        {decision, [], decision_reason(policy, decision, risk, :default)}

      %{"decision" => decision} = override ->
        decision = atomize(decision)
        name = rule_name(override)
        {decision, [name], decision_reason(policy, decision, risk, {:rule, name})}
    end
  end

  defp compile_overrides(overrides) when is_list(overrides),
    do: Enum.flat_map(overrides, &compile_override/1)

  defp compile_override(%{"action" => pattern} = override)
       when is_binary(pattern) and pattern != "" do
    [%{matcher: Glob.compile(pattern), override: override}]
  end

  defp compile_override(_override), do: []

  defp simulation_decision(defaults, overrides, action_id, risk) do
    case find_compiled_override(overrides, action_id) do
      nil -> default_for_tier(defaults, to_string(risk))
      %{"decision" => decision} -> normalize_decision(decision)
    end
  end

  defp find_compiled_override(overrides, action_id) do
    Enum.find_value(overrides, fn %{matcher: matcher, override: override} ->
      if Glob.match_compiled?(matcher, action_id), do: override
    end)
  end

  defp empty_outcome do
    Map.new(@decisions, &{&1, %{count: 0, examples: []}})
  end

  defp add_outcome_action(outcome, decision, action_id) do
    Map.update!(outcome, decision, fn bucket ->
      %{count: bucket.count + 1, examples: keep_example(bucket.examples, action_id)}
    end)
  end

  defp keep_example(examples, action_id) do
    [action_id | examples]
    |> Enum.sort()
    |> Enum.take(3)
  end

  defp default_for_tier(defaults, tier) when is_map(defaults) do
    case Map.get(defaults, tier) do
      decision when decision in @decisions -> decision
      _ -> "deny"
    end
  end

  defp normalize_decision(decision) when decision in @decisions, do: decision
  defp normalize_decision(_decision), do: "deny"

  defp atomize("allow"), do: :allow
  defp atomize("require_approval"), do: :require_approval
  defp atomize("deny"), do: :deny
  defp atomize(_), do: :deny

  def evaluate_with_policy(account_id, attrs, group) when is_binary(account_id) do
    # Resolve the runner/group override (or the account default) for this
    # dispatch's runner; `group` is the runner's group, looked up by the
    # caller (Runs) so Policies stays out of the Runners table.
    policy = resolve_policy(account_id, attrs[:runner_id], group)

    # `evaluate/2` matches on `action_id` (override globs) + `risk` (tier
    # defaults) only. The catalog-authoritative `kind` in `attrs` is the
    # anti-spoofing field carried by `Runs.evaluate_and_dispatch`; the
    # evaluator never reads it, so it isn't threaded into `match_ctx`.
    # `risk` arrives as the catalog's Ecto.Enum atom; the stored rules
    # key their tier defaults by string, so bridge here.
    match_ctx = %{
      "action_id" => attrs[:action_id],
      "risk" => to_string(attrs[:risk] || "low")
    }

    {decision, matched, reason} = evaluate(policy, match_ctx)
    {decision, matched, reason, policy}
  end

  defp decision_reason(policy, decision, risk, :default) do
    "#{policy_subject(policy)} #{decision_phrase(decision)} #{risk}-risk actions by default."
  end

  defp decision_reason(policy, decision, risk, {:rule, name}) do
    "#{policy_subject(policy)} rule “#{name}” #{decision_phrase(decision)} this #{risk}-risk action."
  end

  defp policy_subject(%Policy{scope_type: :runner}), do: "This runner’s policy"

  defp policy_subject(%Policy{scope_type: :group, scope_value: group})
       when is_binary(group) and group != "",
       do: "The “#{group}” group policy"

  defp policy_subject(%Policy{scope_type: :account}), do: "The account policy"
  defp policy_subject(_policy), do: "The policy"

  defp decision_phrase(:allow), do: "allows"
  defp decision_phrase(:require_approval), do: "requires approval for"
  defp decision_phrase(:deny), do: "denies"

  defp normalize_risk(nil), do: "low"
  defp normalize_risk(risk) when risk in @risk_tiers, do: risk
  defp normalize_risk(_risk), do: "unknown"

  defp rule_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp rule_name(%{"action" => action}) when is_binary(action), do: action
  defp rule_name(_), do: "unnamed"

  # -- Audit diff ----------------------------------------------------

  @doc false
  def diff_rules(before_rules, after_rules) do
    before_rules = before_rules || @default_rules
    after_rules = after_rules || @default_rules

    %{
      "defaults" => diff_defaults(defaults_for(before_rules), defaults_for(after_rules)),
      "approval" => diff_approval(approval_for(before_rules), approval_for(after_rules)),
      "overrides" => diff_overrides(overrides_for(before_rules), overrides_for(after_rules))
    }
  end

  # Persisted rules are normally constrained by Policy.Changeset. Keep dispatch
  # and audit resilient to a manually-corrupted JSONB row anyway: malformed
  # defaults become the existing default_for_tier/2 deny fallback, and malformed
  # overrides cannot match an action.
  defp defaults_for(rules) when is_map(rules) do
    case rules["defaults"] do
      %{} = defaults -> defaults
      _ -> %{}
    end
  end

  defp defaults_for(_), do: %{}

  defp overrides_for(rules) when is_map(rules) do
    case rules["overrides"] do
      overrides when is_list(overrides) -> overrides
      _ -> []
    end
  end

  defp overrides_for(_), do: []

  defp approval_for(rules) when is_map(rules) do
    case rules["approval"] do
      %{} = approval -> approval
      _ -> %{}
    end
  end

  defp approval_for(_), do: %{}

  defp diff_approval(before_approval, after_approval) do
    Enum.reduce(~w[min_approvals allow_self_approval], %{}, fn field, changes ->
      before_value = before_approval[field]
      after_value = after_approval[field]

      if before_value == after_value,
        do: changes,
        else: Map.put(changes, field, %{"from" => before_value, "to" => after_value})
    end)
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

  # First-match order matters, and duplicate action globs are valid. Pair exact
  # rows first, consuming one occurrence at a time, then pair the remaining rows
  # with the same action in list order. Without stable rule IDs this preserves
  # all additions/removals without inventing identity across different globs.
  defp diff_overrides(before_list, after_list) do
    {unchanged, before_remaining, after_remaining} =
      pair_overrides(indexed_overrides(before_list), indexed_overrides(after_list), fn
        {before_override, _}, {after_override, _} -> before_override == after_override
      end)

    {modified, removed, added} =
      pair_overrides(before_remaining, after_remaining, fn
        {before_override, _}, {after_override, _} ->
          before_override["action"] == after_override["action"]
      end)

    changed =
      Enum.map(modified, fn {{before_override, _}, {after_override, _}} ->
        %{
          "action" => after_override["action"],
          "from" => before_override,
          "to" => after_override
        }
      end)

    # Compare the relative order of retained rows. Inserting or removing a row
    # shifts positions but does not, on its own, reorder the surviving rules.
    after_indexes =
      (unchanged ++ modified)
      |> Enum.sort_by(fn {{_, before_index}, _} -> before_index end)
      |> Enum.map(fn {_, {_, after_index}} -> after_index end)

    %{
      "added" => Enum.map(added, &elem(&1, 0)),
      "removed" => Enum.map(removed, &elem(&1, 0)),
      "changed" => changed,
      "order_changed" => after_indexes != Enum.sort(after_indexes)
    }
  end

  defp indexed_overrides(overrides) do
    overrides
    |> Enum.with_index()
    |> Enum.filter(fn {override, _} -> is_map(override) and is_binary(override["action"]) end)
  end

  defp pair_overrides(before_entries, after_entries, matches?) do
    {pairs, remaining_before, remaining_after} =
      Enum.reduce(after_entries, {[], before_entries, []}, fn after_entry,
                                                              {pairs, pending, unmatched} ->
        case Enum.split_while(pending, &(not matches?.(&1, after_entry))) do
          {_prefix, []} ->
            {pairs, pending, [after_entry | unmatched]}

          {prefix, [before_entry | suffix]} ->
            {[{before_entry, after_entry} | pairs], prefix ++ suffix, unmatched}
        end
      end)

    {Enum.reverse(pairs), remaining_before, Enum.reverse(remaining_after)}
  end
end
