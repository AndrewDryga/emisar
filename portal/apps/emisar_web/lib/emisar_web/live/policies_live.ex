defmodule EmisarWeb.PoliciesLive do
  @moduledoc """
  Policy editor. One page, everything live-editable:

    * **Default policy** — the base (the account-scoped policy, `scope_type:
      :account`, labeled "Default policy" in the UI). Risk-tier defaults +
      per-action overrides. Applies to every runner.
    * **Targeted rulesets** — an inline list of per-runner / per-group
      policies. Add one, pick a runner or group, edit its rules. A ruleset
      **replaces** the default policy for that target (most specific wins:
      runner > group > account), it doesn't layer on top — so what a unit
      shows is exactly what runs there.

  Each editor unit is its own form with its own Save (a scoped ruleset is its
  own policy row, version, and audit entry). Events carry an `editor`
  discriminator — `"account"` or a ruleset uid — so one set of handlers
  drives every unit.
  """
  use EmisarWeb, :live_view
  alias Emisar.Catalog
  alias Emisar.Policies
  alias Emisar.Runners
  alias EmisarWeb.Permissions

  @decisions Policies.decisions()
  @tiers Policies.risk_tiers()

  # Non-breaking spaces so the browser keeps the indent (ASCII whitespace in an
  # <option> is stripped) — nests runners under their group in the target picker.
  @runner_indent "    "

  def mount(_params, _session, socket) do
    socket =
      assign(socket, page_title: "Policy", loading?: not connected?(socket), load_error?: false)

    {:ok, if(connected?(socket), do: load_all(socket), else: socket)}
  end

  # Load every editor the page needs: the default (account-scoped) policy, the existing
  # runner/group rulesets, and the runner/group pickers new rulesets target.
  defp load_all(socket) do
    subject = socket.assigns.current_subject
    runners = list_runners(subject)

    account_policy =
      case Policies.fetch_policy(subject) do
        {:ok, policy} -> policy
        {:error, _} -> nil
      end

    account_editor =
      account_policy |> build_account_editor() |> Map.put(:catalog, load_account_catalog(subject))

    # A failed scoped-policy read must read as an error, not an empty ruleset
    # list — "No targeted rulesets yet" would wrongly imply none are configured.
    {rulesets, load_error?} =
      case Policies.list_scoped_policies(subject) do
        {:ok, policies} ->
          {Enum.map(policies, fn policy ->
             policy |> build_ruleset_editor() |> put_ruleset_catalog(runners, subject)
           end), false}

        {:error, _} ->
          {[], true}
      end

    socket
    |> assign(:loading?, false)
    |> assign(:load_error?, load_error?)
    |> assign(:can_manage?, Policies.subject_can_manage_policies?(subject))
    |> assign(:account, account_editor)
    |> assign(:rulesets, rulesets)
    |> assign(:runners, runners)
    |> assign(:groups, list_groups(subject))
  end

  # The catalog the account default governs — every advertised action's worst
  # risk as `%{action_id => risk}`; the rail turns it into a live allow / needs-
  # approval / deny outcome. A failed read is an empty catalog (the rail shows
  # the connect-a-runner hint), never a crash.
  defp load_account_catalog(subject) do
    case Catalog.action_risks_for_account(subject) do
      {:ok, catalog} -> catalog
      {:error, _} -> %{}
    end
  end

  # The target catalog a ruleset governs (its runner, or its group's runners) —
  # so the rail speaks for THAT target, not account-wide. A group resolves to its
  # runners' ids from the already-loaded @runners.
  defp put_ruleset_catalog(ruleset, runners, subject) do
    catalog =
      case Catalog.action_risks_for_runner_ids(ruleset_runner_ids(ruleset, runners), subject) do
        {:ok, catalog} -> catalog
        {:error, _} -> %{}
      end

    Map.put(ruleset, :catalog, catalog)
  end

  defp ruleset_runner_ids(%{scope_type: :runner, scope_value: runner_id}, _runners),
    do: [runner_id]

  defp ruleset_runner_ids(%{scope_type: :group, scope_value: group}, runners),
    do: runners |> Enum.filter(&(&1.group == group)) |> Enum.map(& &1.id)

  defp ruleset_runner_ids(_ruleset, _runners), do: []

  defp build_account_editor(policy) do
    rules = (policy && policy.rules) || Policies.default_rules()
    defaults = normalize_defaults(rules["defaults"])
    overrides = normalize_overrides(rules["overrides"])
    approval = normalize_approval(rules)

    %{
      uid: "account",
      scope_type: :account,
      scope_value: "",
      defaults: defaults,
      overrides: overrides,
      approval: approval,
      # Snapshot of the saved rules: editor_dirty?/1 compares the live edits to
      # this, so reverting a change back clears the Save button (not a one-way flag).
      baseline_rules: to_rules(defaults, overrides, approval),
      policy: policy,
      rules_errors: []
    }
  end

  defp build_ruleset_editor(%Policies.Policy{} = policy) do
    rules = policy.rules || Policies.default_rules()
    defaults = normalize_defaults(rules["defaults"])
    overrides = normalize_overrides(rules["overrides"])
    approval = normalize_approval(rules)

    %{
      uid: policy.id,
      scope_type: policy.scope_type,
      scope_value: policy.scope_value,
      defaults: defaults,
      overrides: overrides,
      approval: approval,
      baseline_rules: to_rules(defaults, overrides, approval),
      policy: policy,
      rules_errors: []
    }
  end

  # A blank, not-yet-targeted ruleset, seeded from the default policy so the
  # operator tweaks the live posture rather than starting from an empty one —
  # important under replace-semantics, where a ruleset that dropped the
  # account's deny-overrides would silently widen access for that target.
  defp new_ruleset(account) do
    %{
      uid: "new-" <> Integer.to_string(System.unique_integer([:positive])),
      scope_type: nil,
      scope_value: "",
      defaults: account.defaults,
      overrides: account.overrides,
      approval: account.approval,
      baseline_rules: to_rules(account.defaults, account.overrides, account.approval),
      # Filled in once a target is picked (set_target); no target = no catalog.
      catalog: %{},
      policy: nil,
      rules_errors: []
    }
  end

  defp list_runners(subject) do
    case Runners.list_all_runners_for_account(subject) do
      {:ok, runners} -> runners
      {:error, _} -> []
    end
  end

  defp list_groups(subject) do
    case Runners.list_group_summaries(subject) do
      {:ok, rows} -> rows |> Enum.map(&elem(&1, 0)) |> Enum.reject(&blank?/1) |> Enum.sort()
      {:error, _} -> []
    end
  end

  # -- Events ---------------------------------------------------------

  def handle_event("form_change", %{"editor" => editor_id, "policy" => params}, socket),
    do: {:noreply, apply_policy_params(socket, editor_id, params)}

  def handle_event("form_change", _params, socket), do: {:noreply, socket}

  def handle_event("add_override", %{"editor" => editor_id}, socket) do
    {:noreply,
     update_editor(socket, editor_id, fn editor ->
       %{editor | overrides: editor.overrides ++ [empty_override()]}
     end)}
  end

  def handle_event("remove_override", %{"editor" => editor_id, "index" => idx}, socket) do
    case Integer.parse(idx) do
      {i, _} ->
        {:noreply,
         update_editor(socket, editor_id, fn editor ->
           %{editor | overrides: List.delete_at(editor.overrides, i)}
         end)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("add_ruleset", _params, socket) do
    if Policies.subject_can_manage_policies?(socket.assigns.current_subject) do
      {:noreply,
       assign(socket, :rulesets, socket.assigns.rulesets ++ [new_ruleset(socket.assigns.account)])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_target", %{"uid" => uid, "target" => target}, socket) do
    {scope_type, scope_value} = parse_target(target)

    {:noreply,
     update_editor(socket, uid, fn editor ->
       editor = %{editor | scope_type: scope_type, scope_value: scope_value}
       put_ruleset_catalog(editor, socket.assigns.runners, socket.assigns.current_subject)
     end)}
  end

  def handle_event("set_target", _params, socket), do: {:noreply, socket}

  def handle_event("remove_ruleset", %{"uid" => uid}, socket) do
    case find_ruleset(socket, uid) do
      # Saved ruleset — deleting it is a real mutation, so gate + audit.
      %{policy: %Policies.Policy{} = policy} ->
        Permissions.gated(
          socket,
          Policies.subject_can_manage_policies?(socket.assigns.current_subject),
          &delete_ruleset(&1, policy, uid)
        )

      # Not-yet-saved card — just drop it from the page.
      %{} ->
        {:noreply,
         assign(socket, :rulesets, Enum.reject(socket.assigns.rulesets, &(&1.uid == uid)))}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("save", %{"editor" => editor_id} = params, socket) do
    Permissions.gated(
      socket,
      Policies.subject_can_manage_policies?(socket.assigns.current_subject),
      fn socket ->
        socket = apply_policy_params(socket, editor_id, params["policy"])
        save_editor(socket, get_editor(socket, editor_id))
      end
    )
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  defp save_editor(socket, %{scope_type: :account} = editor),
    do: persist(socket, editor, &Policies.save_rules/2)

  # A crafted `set_target` event (IL-15 — never trust the rendered UI) can carry a
  # runner id outside the account; resolve it against the subject before persisting
  # so the editor can't write an inert `(account, :runner, <foreign/garbage>)` row.
  # `:group` is a free-form name (a policy may legitimately pre-date the runners
  # assigned to it), so it isn't resolution-checked.
  defp save_editor(socket, %{scope_type: :runner, scope_value: runner_id} = editor) do
    case Runners.fetch_runner_by_id(runner_id, socket.assigns.current_subject) do
      {:ok, _runner} ->
        persist(socket, editor, fn rules, subject ->
          Policies.save_scoped_rules(rules, :runner, runner_id, subject)
        end)

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That runner isn't in this account.")}
    end
  end

  defp save_editor(socket, %{scope_type: :group, scope_value: value} = editor) do
    persist(socket, editor, fn rules, subject ->
      Policies.save_scoped_rules(rules, :group, value, subject)
    end)
  end

  defp save_editor(socket, _editor),
    do: {:noreply, put_flash(socket, :error, "Choose a runner or group for this ruleset first.")}

  defp persist(socket, editor, save_fun) do
    rules = to_rules(editor.defaults, editor.overrides, editor.approval)

    case save_fun.(rules, socket.assigns.current_subject) do
      {:ok, policy} ->
        {:noreply,
         socket |> put_flash(:info, "Policy saved.") |> replace_saved(editor.uid, policy)}

      # The UI prevents invalid policies (constrained selects + monotonic
      # enforcement + blank rows dropped), so this is a defensive net: show
      # the rules-level error inline on the card it belongs to, not a flash.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         update_editor(socket, editor.uid, fn editor ->
           %{editor | rules_errors: changeset_rules_errors(changeset)}
         end)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not save policy.")}
    end
  end

  # Swap the just-saved editor for one rebuilt from the returned row (a new
  # ruleset's uid flips from `new-…` to the policy id), leaving every other
  # card's in-progress edits untouched — no full reload, no lost work.
  # Saving the policy doesn't change the FLEET's catalog, so carry the existing
  # one onto the rebuilt editor rather than re-reading it.
  defp replace_saved(socket, "account", policy) do
    rebuilt = Map.put(build_account_editor(policy), :catalog, socket.assigns.account.catalog)
    assign(socket, :account, rebuilt)
  end

  defp replace_saved(socket, old_uid, policy) do
    rebuilt =
      policy
      |> build_ruleset_editor()
      |> put_ruleset_catalog(socket.assigns.runners, socket.assigns.current_subject)

    rulesets =
      Enum.map(socket.assigns.rulesets, fn ruleset ->
        if ruleset.uid == old_uid, do: rebuilt, else: ruleset
      end)

    assign(socket, :rulesets, rulesets)
  end

  defp delete_ruleset(socket, policy, uid) do
    case Policies.delete_scoped_policy(policy, socket.assigns.current_subject) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ruleset removed — that scope falls back to the default policy.")
         |> assign(:rulesets, Enum.reject(socket.assigns.rulesets, &(&1.uid == uid)))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove ruleset.")}
    end
  end

  # -- Editor state ---------------------------------------------------

  defp get_editor(socket, "account"), do: socket.assigns.account
  defp get_editor(socket, uid), do: find_ruleset(socket, uid)

  defp find_ruleset(socket, uid), do: Enum.find(socket.assigns.rulesets, &(&1.uid == uid))

  # Dirtiness isn't a stored flag — editor_dirty?/1 computes it against the
  # editor's baseline_rules, so reverting an edit back to the saved value clears
  # the Save button (a one-way latch left it stuck emerald).
  defp update_editor(socket, "account", fun),
    do: assign(socket, :account, fun.(socket.assigns.account))

  defp update_editor(socket, uid, fun) do
    rulesets =
      Enum.map(socket.assigns.rulesets, fn ruleset ->
        if ruleset.uid == uid, do: fun.(ruleset), else: ruleset
      end)

    assign(socket, :rulesets, rulesets)
  end

  # The Save button is emerald only while the editor differs from what's saved: a
  # new (unsaved) ruleset is always dirty; otherwise the live rules are compared
  # to the baseline snapshot, so a revert flips it back to outlined.
  defp editor_dirty?(%{scope_type: :account} = editor), do: rules_changed?(editor)
  defp editor_dirty?(%{policy: nil}), do: true
  defp editor_dirty?(editor), do: rules_changed?(editor)

  defp rules_changed?(editor),
    do: to_rules(editor.defaults, editor.overrides, editor.approval) != editor.baseline_rules

  defp apply_policy_params(socket, editor_id, params) when is_map(params) do
    update_editor(socket, editor_id, fn editor ->
      defaults =
        editor.defaults
        |> merge_defaults(params["defaults"] || %{})
        |> enforce_monotonic_defaults()

      overrides = merge_overrides(editor.overrides, params["overrides"] || [])
      approval = merge_approval(editor.approval, params["approval"] || %{})

      %{
        editor
        | defaults: defaults,
          overrides: overrides,
          approval: approval,
          rules_errors: rules_errors(defaults, overrides, approval)
      }
    end)
  end

  defp apply_policy_params(socket, _editor_id, _params), do: socket

  defp parse_target(target) do
    case String.split(target, ":", parts: 2) do
      ["runner", id] -> {:runner, id}
      ["group", name] -> {:group, name}
      _ -> {nil, ""}
    end
  end

  defp normalize_defaults(nil), do: default_defaults()

  defp normalize_defaults(%{} = defaults) do
    Enum.into(@tiers, %{}, fn tier ->
      value = defaults[tier]
      {tier, if(value in @decisions, do: value, else: default_decision(tier))}
    end)
  end

  defp default_defaults, do: Enum.into(@tiers, %{}, fn tier -> {tier, default_decision(tier)} end)

  defp default_decision("low"), do: "allow"
  defp default_decision("medium"), do: "allow"
  defp default_decision("high"), do: "require_approval"
  defp default_decision("critical"), do: "deny"

  defp normalize_overrides(nil), do: []

  defp normalize_overrides(list) when is_list(list) do
    Enum.map(list, fn override ->
      %{
        "name" => override["name"] || "",
        "action" => override["action"] || "",
        "decision" =>
          if(override["decision"] in @decisions, do: override["decision"], else: "allow")
      }
    end)
  end

  defp normalize_overrides(_), do: []

  defp empty_override, do: %{"name" => "", "action" => "", "decision" => "allow"}

  # The approval-gate editor state, read off the stored rules (defaults when
  # the section is absent — rules saved before the gate existed).
  defp normalize_approval(rules) when is_map(rules) do
    %{
      "min_approvals" => Policies.min_approvals_for(rules),
      "allow_self_approval" => Policies.self_approval_allowed?(rules)
    }
  end

  # A native checkbox posts its value only when checked, so an UNCHECKED
  # allow_self_approval (the box absent from params) reads as false. The number
  # input always posts; floor it at 1 to mirror the changeset.
  defp merge_approval(state, form) when is_map(form) do
    %{
      "min_approvals" => parse_min_approvals(form["min_approvals"], state["min_approvals"]),
      "allow_self_approval" => form["allow_self_approval"] == "true"
    }
  end

  defp parse_min_approvals(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} when n >= 1 -> n
      _ -> fallback
    end
  end

  defp parse_min_approvals(_value, fallback), do: fallback

  # The ways a scoped ruleset's approval gate is laxer than the account default
  # (fewer required approvals, or self-approval the default forbids). Empty when
  # it's at least as strict. The account default itself is never compared.
  defp approval_weakenings(scoped, default) do
    Enum.reject(
      [
        scoped["min_approvals"] < default["min_approvals"] &&
          "requires fewer approvals (#{scoped["min_approvals"]} vs #{default["min_approvals"]})",
        (scoped["allow_self_approval"] and not default["allow_self_approval"]) &&
          "lets the requester approve their own action"
      ],
      &(&1 == false)
    )
  end

  # A "require approval" gate that adds no SECOND party — one approval needed and
  # the requester may supply it. `to_string` guards both the int state and a raw
  # form string mid-edit.
  defp single_reviewer_gate?(approval),
    do: approval["allow_self_approval"] && to_string(approval["min_approvals"]) == "1"

  defp approval_count(n) when is_integer(n) and n >= 1, do: n

  defp approval_count(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} when i >= 1 -> i
      _ -> 1
    end
  end

  defp approval_count(_), do: 1

  # Singular when exactly one approval is required — "1 distinct operators" is wrong,
  # and "distinct" is meaningless for a single approver (nothing to be distinct from).
  defp approval_operators_noun(min_approvals) do
    if approval_count(min_approvals) == 1, do: "operator", else: "distinct operators"
  end

  defp weakening_sentence([one]), do: one
  defp weakening_sentence(many), do: Enum.join(many, " and ")

  defp merge_defaults(state, form) when is_map(form) do
    Enum.into(@tiers, state, fn tier ->
      value = form[tier] || state[tier]
      {tier, if(value in @decisions, do: value, else: state[tier])}
    end)
  end

  # Walk left-to-right, lifting any tier that's more permissive than its
  # predecessor up to the predecessor's level — so changing `low` to deny
  # instantly bumps the rest, and the operator never sees a transient invalid
  # state the server would reject.
  defp enforce_monotonic_defaults(defaults) do
    @tiers
    |> Enum.reduce({defaults, 0}, fn tier, {acc, floor_rank} ->
      cur_rank = Policies.decision_rank(acc[tier])

      {value, rank} =
        if cur_rank < floor_rank,
          do: {decision_at_rank(floor_rank), floor_rank},
          else: {acc[tier], cur_rank}

      {Map.put(acc, tier, value), rank}
    end)
    |> elem(0)
  end

  defp decision_at_rank(0), do: "allow"
  defp decision_at_rank(1), do: "require_approval"
  defp decision_at_rank(2), do: "deny"

  defp merge_overrides(state, form) do
    form_list = normalize_indexed(form)

    state
    |> Enum.with_index()
    |> Enum.map(fn {override, i} ->
      case Enum.at(form_list, i) do
        nil ->
          override

        form_override ->
          Map.merge(override, Map.take(form_override, ["name", "action", "decision"]))
      end
    end)
  end

  defp normalize_indexed(list) when is_list(list), do: list

  defp normalize_indexed(%{} = map) do
    map
    |> Enum.sort_by(fn {key, _} ->
      case Integer.parse(to_string(key)) do
        {n, _} -> n
        :error -> 0
      end
    end)
    |> Enum.map(fn {_, value} -> value end)
  end

  defp normalize_indexed(_), do: []

  defp to_rules(defaults, overrides, approval) do
    %{
      "schema_version" => 2,
      "defaults" => defaults,
      "overrides" =>
        overrides
        |> Enum.reject(&blank_action?/1)
        |> Enum.map(fn override ->
          %{
            "name" => String.trim(override["name"] || ""),
            "action" => String.trim(override["action"]),
            "decision" => override["decision"]
          }
        end),
      "approval" => approval
    }
  end

  defp rules_errors(defaults, overrides, approval) do
    to_rules(defaults, overrides, approval)
    |> Policies.change_policy()
    |> changeset_rules_errors()
  end

  defp changeset_rules_errors(changeset),
    do: for({:rules, {msg, _opts}} <- changeset.errors, do: msg)

  defp blank_action?(override), do: blank?(override["action"])

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  # -- Target helpers -------------------------------------------------

  defp target_name(%{scope_type: :runner, scope_value: id}, runners), do: runner_name(runners, id)
  defp target_name(%{scope_type: :group, scope_value: group}, _runners), do: group

  # Resolve a runner id to its name; fall back to the id if the runner was
  # since deleted so the ruleset stays identifiable.
  defp runner_name(runners, id) do
    case Enum.find(runners, &(&1.id == id)) do
      %{name: name} -> name
      nil -> id
    end
  end

  defp target_selected?(ruleset, scope_type, scope_value),
    do: ruleset.scope_type == scope_type and ruleset.scope_value == scope_value

  # Ordered options for the target picker: each group as a selectable header,
  # then its runners indented beneath, then any ungrouped runners — one tree, so
  # groups are pickable (a native <optgroup> label isn't) with no separate
  # runners-vs-groups split. A target another ruleset already claims is disabled
  # (kept visible so the whole fleet reads at a glance). The current card's own
  # pick is excluded from `taken`, so it stays selectable.
  defp target_options(runners, groups, ruleset, rulesets) do
    taken = taken_targets(rulesets, ruleset.uid)

    grouped =
      Enum.flat_map(groups, fn group ->
        header = target_option(:group, group, group, ruleset, taken)
        [header | Enum.map(runners_in_group(runners, group), &runner_option(&1, ruleset, taken))]
      end)

    case ungrouped_runners(runners) do
      [] ->
        grouped

      ungrouped ->
        header = %{value: "", label: "Ungrouped", disabled: true, selected: false}
        grouped ++ [header | Enum.map(ungrouped, &runner_option(&1, ruleset, taken))]
    end
  end

  defp target_option(scope_type, scope_value, name, ruleset, taken) do
    taken? = MapSet.member?(taken, {scope_type, scope_value})

    %{
      value: "#{scope_type}:#{scope_value}",
      label: if(taken?, do: name <> " — has a ruleset", else: name),
      disabled: taken?,
      selected: target_selected?(ruleset, scope_type, scope_value)
    }
  end

  defp runner_option(runner, ruleset, taken) do
    option = target_option(:runner, runner.id, runner.name, ruleset, taken)
    %{option | label: @runner_indent <> option.label}
  end

  defp runners_in_group(runners, group),
    do: runners |> Enum.filter(&(&1.group == group)) |> Enum.sort_by(& &1.name)

  defp ungrouped_runners(runners),
    do: runners |> Enum.filter(&blank?(&1.group)) |> Enum.sort_by(& &1.name)

  defp taken_targets(rulesets, current_uid) do
    for ruleset <- rulesets,
        ruleset.uid != current_uid,
        not is_nil(ruleset.scope_type),
        into: MapSet.new(),
        do: {ruleset.scope_type, ruleset.scope_value}
  end

  # Any target still free to claim — gates the "Add ruleset" button.
  defp addable_any?(runners, groups, rulesets) do
    taken = taken_targets(rulesets, nil)

    Enum.any?(groups, &(not MapSet.member?(taken, {:group, &1}))) or
      Enum.any?(runners, &(not MapSet.member?(taken, {:runner, &1.id})))
  end

  # -- Render ---------------------------------------------------------

  # No-op for the broadcasts the on_mount badge/fleet hooks forward (approvals,
  # pack trust, runner presence). The hooks own those nav cues; this page ignores them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:policies}
      width={:table}
    >
      <:title>Policy</:title>

      <.loading_state :if={@loading?} />

      <div :if={not @loading?} class="space-y-12">
        <div class="space-y-4">
          <.page_intro>
            Each action's risk tier meets your default policy — allow, require approval,
            or deny — with overrides and targeted rulesets for the exceptions.
            <.doc_link href="/docs/policies-and-approvals">Policy docs</.doc_link>
          </.page_intro>

          <%!-- A quiet naked line, not a boxed note — the viewer fact isn't an
               actionable warning (§8.1). --%>
          <p :if={not @can_manage?} class="text-xs text-zinc-500">
            You can view the policy, but only owners and admins can change it.
          </p>
        </div>

        <%!-- Each policy — the default and every targeted ruleset — pairs its
             editor with a rail that PREVIEWS the decision: the live rules run
             over that target's catalog, shown as allow / needs-approval / deny.
             The editor sits naked on the canvas; the only boxes are the
             self-contained controls and the earned amber warnings. --%>
        <section>
          <.section_header title="Default policy">
            <:subtitle>
              The base decision for every runner, by risk tier — unless a targeted ruleset below overrides it.
            </:subtitle>
          </.section_header>

          <div class="grid grid-cols-1 gap-8 lg:grid-cols-4 lg:items-start">
            <div class="lg:col-span-3">
              <.policy_fields
                editor_id="account"
                defaults={@account.defaults}
                overrides={@account.overrides}
                approval={@account.approval}
                rules_errors={@account.rules_errors}
                can_manage={@can_manage?}
                save_label="Save default policy"
                dirty={editor_dirty?(@account)}
                top_margin="mt-0"
              />
            </div>
            <aside class="lg:col-span-1">
              <.policy_rail
                catalog={@account.catalog}
                defaults={@account.defaults}
                overrides={@account.overrides}
                approval={@account.approval}
                catalog_path={~p"/app/#{@current_account}/packs"}
                target="your fleet"
              />
            </aside>
          </div>
        </section>

        <section>
          <.section_header title="Targeted rulesets">
            <:subtitle>
              A ruleset <strong class="text-zinc-300">replaces</strong>
              the default policy for one runner or group. Most specific wins — runner,
              then group, then the default policy.
            </:subtitle>
          </.section_header>

          <.empty_state
            :if={@load_error? and @rulesets == []}
            tone={:danger}
            icon="hero-exclamation-triangle"
            title="Couldn't load targeted rulesets"
          >
            This is a load error, not an empty configuration — rulesets may well be set.
            Refresh the page; if it persists, your access to this account may have changed.
          </.empty_state>

          <%!-- Viewer with nothing to see gets the quiet fact; for a manager
               the Add-ruleset composer below IS the empty state (the runbook
               precedent — no dashed hint above a dashed composer). --%>
          <p
            :if={not @load_error? and @rulesets == [] and not @can_manage?}
            class="text-sm text-zinc-500"
          >
            No targeted rulesets — every runner uses the default policy above.
          </p>

          <div :if={@rulesets != []} class="space-y-8">
            <div :for={ruleset <- @rulesets}>
              <.ruleset_unit
                ruleset={ruleset}
                account_approval={@account.approval}
                runners={@runners}
                groups={@groups}
                rulesets={@rulesets}
                can_manage={@can_manage?}
                catalog_path={~p"/app/#{@current_account}/packs"}
              />
            </div>
          </div>

          <div :if={@can_manage? and not @load_error?} class={@rulesets != [] && "mt-8"}>
            <.add_row
              label="Add ruleset"
              phx-click="add_ruleset"
              disabled={not addable_any?(@runners, @groups, @rulesets)}
              title={
                if not addable_any?(@runners, @groups, @rulesets),
                  do: "Every runner and group already has a ruleset (or none exist yet)"
              }
            />
          </div>
        </section>
      </div>
    </.dashboard_shell>
    """
  end

  attr :catalog, :map, required: true, doc: "%{action_id => risk} the policy governs"
  attr :defaults, :map, required: true
  attr :overrides, :list, required: true
  attr :approval, :map, required: true
  attr :catalog_path, :string, required: true, doc: "link to the full action catalog (Packs)"

  attr :target, :string,
    required: true,
    doc: "who this policy applies to, e.g. \"your fleet\" or a group name"

  # The side rail: apply the LIVE rules to the target's catalog and preview the
  # decision — allow / needs-approval / deny, with a few example actions — so the
  # operator sees what the policy DOES, live as they edit. Below it, the catalog's
  # risk profile. Recomputes on every render (pure, in-memory).
  defp policy_rail(assigns) do
    rules = to_rules(assigns.defaults, assigns.overrides, assigns.approval)

    assigns =
      assign(assigns,
        outcome: Policies.simulate_outcome(rules, assigns.catalog),
        breakdown: Catalog.risk_breakdown_of(assigns.catalog),
        total: map_size(assigns.catalog)
      )

    ~H"""
    <div class="space-y-5">
      <div>
        <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">In effect</h3>
        <p :if={@total > 0} class="mt-1 text-xs leading-relaxed text-zinc-500">
          What this policy decides for {@target}'s
          <span class="font-medium text-zinc-300">{@total}</span>
          {ngettext_action(@total)}.
        </p>
        <%!-- No catalog yet: the empty note stands in as the subtitle — no
             "…for your fleet's 0 actions." line to state a count of nothing. --%>
        <p :if={@total == 0} class="mt-1 text-xs leading-relaxed text-zinc-500">
          No actions advertised on this target yet — decisions appear once a runner reports its catalog.
        </p>
      </div>

      <div :if={@total > 0} class="space-y-3">
        <.outcome_row tone={:brand} label="Allowed" stat={@outcome["allow"]} />
        <.outcome_row tone={:amber} label="Needs approval" stat={@outcome["require_approval"]} />
        <.outcome_row tone={:rose} label="Denied" stat={@outcome["deny"]} />
      </div>

      <%!-- The catalog's danger profile — the counts the tier decisions above act
           on. Compact: pill + count, most-severe first. "View all" opens the full
           action catalog (Packs) in a new tab, so an in-flight edit is untouched. --%>
      <div :if={@total > 0} class="border-t border-zinc-800/70 pt-4">
        <div class="flex items-baseline justify-between">
          <h3 class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
            Catalog by risk
          </h3>
          <.link
            href={@catalog_path}
            target="_blank"
            class="inline-flex items-center gap-0.5 text-[10px] font-medium text-zinc-500 hover:text-zinc-300"
          >
            View all <.icon name="hero-arrow-top-right-on-square" class="h-2.5 w-2.5" />
          </.link>
        </div>
        <dl class="mt-3 space-y-2">
          <div
            :for={tier <- ["critical", "high", "medium", "low"]}
            class="flex items-center justify-between"
          >
            <dt><.risk_pill risk={tier} /></dt>
            <dd class="text-xs tabular-nums text-zinc-400">{@breakdown[tier]}</dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end

  attr :tone, :atom, required: true
  attr :label, :string, required: true
  attr :stat, :map, required: true, doc: "%{count, examples}"

  # One decision line in the rail: a semantic dot + label + count, with a muted
  # mono example line under it (the WHICH, not just how many).
  defp outcome_row(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <.status_dot tone={@tone} />
          <span class="text-sm text-zinc-300">{@label}</span>
        </div>
        <span class="text-sm font-semibold tabular-nums text-zinc-100">{@stat.count}</span>
      </div>
      <p
        :if={@stat.examples != []}
        class="mt-1 truncate pl-4 font-mono text-[10px] text-zinc-600"
        title={Enum.join(@stat.examples, ", ")}
      >
        {Enum.join(@stat.examples, ", ")}
      </p>
    </div>
    """
  end

  defp ngettext_action(1), do: "action"
  defp ngettext_action(_), do: "actions"

  attr :ruleset, :map, required: true
  attr :account_approval, :map, required: true
  attr :runners, :list, required: true
  attr :groups, :list, required: true
  attr :rulesets, :list, required: true
  attr :can_manage, :boolean, required: true
  attr :catalog_path, :string, required: true, doc: "link to the full action catalog (Packs)"

  # A NAKED unit in the rulesets stack (the runbook step grammar) — the
  # hairline + header row delimit it; a card wash around a whole editor was
  # the island §8.1 bans.
  defp ruleset_unit(assigns) do
    ~H"""
    <div class="grid grid-cols-1 gap-8 lg:grid-cols-4 lg:items-start">
      <div class="lg:col-span-3">
        <%= if @ruleset.policy do %>
          <%!-- Saved ruleset: entity chip + name, and a red modal-confirmed Remove
           (removing it loses the overrides, so it earns the confirm). --%>
          <header class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <.chip upcase>{@ruleset.scope_type}</.chip>
                <span class="truncate text-sm font-semibold text-zinc-100">
                  {target_name(@ruleset, @runners)}
                </span>
              </div>
              <p class="mt-1 text-xs text-zinc-500">
                Replaces the default policy for this {@ruleset.scope_type}.
              </p>
            </div>
            <.confirm_button
              :if={@can_manage}
              id={"remove-ruleset-#{@ruleset.uid}"}
              title="Remove this ruleset?"
              confirm_label="Remove ruleset"
              variant={:secondary}
              tone={:rose}
              size={:lg}
              icon="hero-trash"
              class="h-10"
              on_confirm={JS.push("remove_ruleset", value: %{uid: @ruleset.uid})}
            >
              <:body>This {@ruleset.scope_type} falls back to the default policy.</:body>
              Remove
            </.confirm_button>
          </header>
        <% else %>
          <%!-- Unsaved ruleset: the target picker with a red Remove aligned to the
           select box (items-end + matching size). Nothing's persisted, so Remove
           drops the card directly — no confirm modal. A form (not a lone select)
           carries the uid as a hidden field on the change event. --%>
          <header class="flex items-end gap-3">
            <form phx-change="set_target" class="w-full sm:max-w-xs">
              <input type="hidden" name="uid" value={@ruleset.uid} />
              <%!-- One tree: each group is a selectable header with its runners
               indented beneath it. A native <optgroup> label can't be picked,
               so groups are plain options; a target another ruleset already
               claims is shown disabled. --%>
              <.select
                name="target"
                label="Apply this ruleset to"
                label_variant={:eyebrow}
                disabled={not @can_manage}
                prompt="Choose a runner or group…"
                prompt_selected={is_nil(@ruleset.scope_type)}
                options={target_options(@runners, @groups, @ruleset, @rulesets)}
              />
            </form>
            <.button
              :if={@can_manage}
              variant={:secondary}
              tone={:rose}
              size={:lg}
              type="button"
              phx-click="remove_ruleset"
              phx-value-uid={@ruleset.uid}
              icon="hero-trash"
              class="h-10"
            >
              Remove
            </.button>
          </header>
        <% end %>

        <.policy_fields
          :if={@ruleset.scope_type}
          editor_id={@ruleset.uid}
          defaults={@ruleset.defaults}
          overrides={@ruleset.overrides}
          approval={@ruleset.approval}
          approval_weakenings={approval_weakenings(@ruleset.approval, @account_approval)}
          rules_errors={@ruleset.rules_errors}
          can_manage={@can_manage}
          save_label="Save ruleset"
          dirty={editor_dirty?(@ruleset)}
        />
        <p :if={is_nil(@ruleset.scope_type)} class="mt-4 text-xs text-zinc-500">
          Pick a runner or group above, then set its rules.
        </p>
      </div>
      <aside :if={@ruleset.scope_type} class="lg:col-span-1">
        <.policy_rail
          catalog={@ruleset.catalog}
          defaults={@ruleset.defaults}
          overrides={@ruleset.overrides}
          approval={@ruleset.approval}
          catalog_path={@catalog_path}
          target={target_name(@ruleset, @runners)}
        />
      </aside>
    </div>
    """
  end

  attr :editor_id, :string, required: true
  attr :defaults, :map, required: true
  attr :overrides, :list, required: true
  attr :approval, :map, required: true

  attr :approval_weakenings, :list,
    default: [],
    doc: "ways this scoped gate is laxer than the account default (empty for the default itself)"

  attr :rules_errors, :list, required: true
  attr :can_manage, :boolean, required: true
  attr :save_label, :string, required: true
  attr :dirty, :boolean, default: false

  attr :top_margin, :string,
    default: "mt-6",
    doc:
      "top gap above the box. `mt-6` separates a ruleset box from its header; the default policy passes `mt-0` — its section header already spaces it (and it lines up with the rail)"

  defp policy_fields(assigns) do
    # Self-approval + a single approval adds no SECOND party — the one case worth an
    # amber callout (guidance folded in). A healthy gate shows none.
    assigns = assign(assigns, :single_reviewer?, single_reviewer_gate?(assigns.approval))

    ~H"""
    <%!-- Each policy — the default and every targeted ruleset — is a dashed
         card (the runbook-editor section grammar). A dashed frame with no wash
         is the sanctioned placeholder shape, not a solid island (§8.1). --%>
    <form
      id={"policy-form-" <> @editor_id}
      phx-change="form_change"
      phx-submit="save"
      class={[@top_margin, "space-y-8 rounded-xl border border-dashed border-zinc-800 p-5 sm:p-6"]}
    >
      <input type="hidden" name="editor" value={@editor_id} />

      <%!-- The policy is structured data assembled server-side into one
           `rules` map, so a validation error keys to `:rules`, not a field.
           Render it inline (rose border) on this card — never a flash. The
           constrained selects + monotonic enforcement keep it empty in
           practice; this is the defensive net. --%>
      <.callout :for={msg <- @rules_errors} tone={:rose}>{msg}</.callout>

      <%!-- No "Risk-tier defaults" heading — it just echoes the panel title "Default
           policy". The tier grid is the card's primary content; the panel subtitle
           labels it ("by risk tier") and the tier cards are self-evident. --%>
      <div>
        <div class="grid grid-cols-1 gap-x-4 gap-y-4 sm:grid-cols-2 lg:grid-cols-4">
          <.tier_field
            :for={tier <- ["low", "medium", "high", "critical"]}
            tier={tier}
            value={@defaults[tier]}
            floor_rank={tier_floor_rank(@defaults, tier)}
            can_manage={@can_manage}
          />
        </div>
      </div>

      <div>
        <h3 class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
          Per-action overrides
        </h3>
        <p class="mt-0.5 text-xs text-zinc-500">
          First match wins. Action supports wildcards (e.g. <code class="font-mono text-zinc-300">cassandra.*</code>).
        </p>

        <%!-- Viewer's empty fact; a manager's empty state IS the composer below. --%>
        <p :if={@overrides == [] and not @can_manage} class="mt-4 text-xs text-zinc-500">
          No overrides — the tier defaults above decide every action.
        </p>

        <div :if={@overrides != []} class="mt-2 divide-y divide-zinc-800/70">
          <%!-- First-match wins, so an override whose glob is subsumed by an
               earlier one is dead. Surface it inline (display-only, pure CPU on
               the in-memory rows) so an operator doesn't believe a deny they
               buried under a broader allow is in force. --%>
          <div
            :for={{override, idx} <- Enum.with_index(@overrides)}
            class="py-4 first:pt-0 last:pb-0"
          >
            <.override_row
              editor_id={@editor_id}
              override={override}
              index={idx}
              shadowed_by={shadowed_by(@overrides, idx)}
              can_manage={@can_manage}
            />
          </div>
        </div>

        <%!-- Composer standard: the add affordance sits where the next row
             lands — no twin header button, no dashed hint above a dashed
             composer. --%>
        <div :if={@can_manage} class="mt-4">
          <.add_row label="Add override" phx-click="add_override" phx-value-editor={@editor_id} />
        </div>
      </div>

      <%!-- Approval requirements: WHO may approve (allow_self_approval) and HOW MANY
           (min_approvals) — two independent NAKED knobs (the choice cards and the
           count input are self-contained controls; the recessed wash that used to
           group them was one more island). Selection stays color-neutral on
           purpose — emerald and amber are reserved for the verdict below, the one
           place who + count are judged together, so the risky self-approval choice
           never wears the safe color. The verdict resolves the pair into English. --%>
      <div>
        <h3 class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
          Approval requirements
        </h3>

        <%!-- The two cards name WHO may approve — self-labeling, so no separate
             "Who can approve" eyebrow above them (under the section h3 it read as
             a second title in a row). --%>
        <.choice_cards
          name="policy[approval][allow_self_approval]"
          value={@approval["allow_self_approval"]}
          disabled={!@can_manage}
          columns={2}
          class="mt-3"
        >
          <:card value="false" icon="hero-user-group" title="A different operator">
            No signing off on your own request.
          </:card>
          <:card value="true" icon="hero-user" title="Anyone, incl. requester">
            The requester's own approval can count.
          </:card>
        </.choice_cards>

        <div class="mt-6">
          <.label variant={:eyebrow}>Required approvals</.label>
          <%!-- The eyebrow labels from above; the input and the trailing clause
               share one centered row so they align — an inline eyebrow beside the
               input never lined up with the trailing text. --%>
          <div class="mt-2 flex items-center gap-x-2.5">
            <input
              type="number"
              name="policy[approval][min_approvals]"
              value={@approval["min_approvals"]}
              min="1"
              step="1"
              disabled={!@can_manage}
              class="w-14 rounded-lg border-0 bg-zinc-900 px-2 py-1.5 text-center text-sm font-medium text-zinc-100 ring-1 ring-inset ring-zinc-800 focus:ring-2 focus:ring-inset focus:ring-brand-500 disabled:opacity-50"
            />
            <span class="text-xs text-zinc-500">
              {approval_operators_noun(@approval["min_approvals"])}, before the action runs.
            </span>
          </div>
        </div>

        <%!-- The verdict earns its space only as a WARNING — when self-approval plus a
             single approval lets the requester sign off on their own request. A healthy
             gate shows nothing: the cards + count already say what it does, and a green
             "all good" note is just noise that trains operators to ignore it. It reads
             in the calm icon-caps-a-spine grammar (`event_block`), not a wash box — the
             amber icon carries the severity. The remedy is descriptive, so it shows for
             everyone (a viewer still learns how the gate could be tightened). --%>
        <.event_block
          :if={@single_reviewer?}
          tone={:amber}
          icon="hero-shield-exclamation"
          title="In effect — a single approval is enough, and the requester may approve their own request"
          class="mt-6"
        >
          <:body>Choose a different operator, or raise the count, to add independent review.</:body>
        </.event_block>

        <%!-- A scoped ruleset REPLACES the default wholesale, so an override
             seeded from a pre-gate template can silently weaken the approval
             gate for its target. Nudge the operator when that's the case. --%>
        <.event_block
          :if={@approval_weakenings != []}
          tone={:amber}
          icon="hero-shield-exclamation"
          title="Weaker approval gate than the default policy"
          class="mt-4"
        >
          <:body>
            This ruleset replaces the default for its target, and its gate is laxer — it {weakening_sentence(
              @approval_weakenings
            )}. Tighten it here if that isn't intended.
          </:body>
        </.event_block>
      </div>

      <%!-- The Save button IS the dirty indicator: emerald (primary) when there
           are unsaved edits, quiet outlined (secondary) when the form is clean —
           the house pattern that replaced a trailing "Unsaved changes" chip. --%>
      <div :if={@can_manage} class="flex items-center border-t border-zinc-800/70 pt-5">
        <.button
          type="submit"
          variant={if @dirty, do: :primary, else: :secondary}
          phx-disable-with="Saving..."
        >
          {@save_label}
        </.button>
      </div>
    </form>
    """
  end

  attr :tier, :string, required: true
  attr :value, :string, required: true
  attr :floor_rank, :integer, required: true
  attr :can_manage, :boolean, required: true

  # NAKED tier field (§8.1: fields are self-contained controls) — a box around
  # one labelled select was an island. The wrapping <label> keeps the
  # click-to-focus association. A decision-colored dot beside the eyebrow reads
  # the tier's verdict at a glance (allow=brand, require approval=amber,
  # deny=rose), the same pass/pending/deny palette as everywhere else.
  defp tier_field(assigns) do
    ~H"""
    <label class="block">
      <span class="flex items-center gap-1.5">
        <.status_dot tone={decision_tone(@value)} />
        <span class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">{@tier}</span>
      </span>
      <%!-- Options below the floor are disabled — they'd make this tier more
           permissive than a lower-risk one, which the server rejects. Kept
           visible (not hidden) so the operator sees why. When the floor leaves
           exactly ONE choice, the whole select locks (no click on a foregone
           decision) and a hover tooltip carries the why — the rule that used to
           sit as a standing line under the grid. --%>
      <%!-- flex-col so the select (a block wrapper) stretches to the tooltip's
           full width on the cross axis — the tooltip's own inline-flex row would
           shrink it to content. --%>
      <.tooltip
        :if={locked_tier?(@floor_rank)}
        text="Higher-risk tiers can't be more permissive than lower ones."
        class="w-full flex-col"
      >
        <.tier_select tier={@tier} value={@value} floor_rank={@floor_rank} can_manage={@can_manage} />
      </.tooltip>
      <.tier_select
        :if={not locked_tier?(@floor_rank)}
        tier={@tier}
        value={@value}
        floor_rank={@floor_rank}
        can_manage={@can_manage}
      />
    </label>
    """
  end

  attr :tier, :string, required: true
  attr :value, :string, required: true
  attr :floor_rank, :integer, required: true
  attr :can_manage, :boolean, required: true

  # The tier's decision select. A locked tier (only one legal choice) is
  # disabled even for a manager — the value is already forced by monotonic
  # enforcement, so a non-posting disabled select stays correct on save.
  defp tier_select(assigns) do
    ~H"""
    <.select
      name={"policy[defaults][#{@tier}]"}
      disabled={!@can_manage or locked_tier?(@floor_rank)}
      options={
        Enum.map(decision_options(), fn {label, value} ->
          %{
            value: value,
            label: label,
            disabled: Policies.decision_rank(value) < @floor_rank,
            selected: @value == value
          }
        end)
      }
    />
    """
  end

  # One legal choice left — every decision below the floor is disabled, and the
  # three decisions span ranks 0/1/2, so a floor at the top rank (deny) leaves
  # only deny.
  defp locked_tier?(floor_rank), do: floor_rank >= 2

  defp decision_tone("allow"), do: :brand
  defp decision_tone("require_approval"), do: :amber
  defp decision_tone("deny"), do: :rose
  defp decision_tone(_), do: :neutral

  attr :editor_id, :string, required: true
  attr :override, :map, required: true
  attr :index, :integer, required: true
  attr :shadowed_by, :integer, required: true
  attr :can_manage, :boolean, required: true

  # A NAKED override row — compact fields in the runbook-editor grid grammar,
  # a hairline between rows; the wash box around each row was an island.
  defp override_row(assigns) do
    ~H"""
    <div class="space-y-2 sm:grid sm:grid-cols-12 sm:items-end sm:gap-2 sm:space-y-0">
      <div class="sm:col-span-2">
        <.input
          name={"policy[overrides][#{@index}][name]"}
          value={@override["name"]}
          label="Name"
          label_variant={:eyebrow}
          size={:compact}
          placeholder="optional"
          disabled={!@can_manage}
        />
      </div>
      <div class="sm:col-span-4">
        <.input
          name={"policy[overrides][#{@index}][action]"}
          value={@override["action"]}
          label="Action (glob ok)"
          label_variant={:eyebrow}
          size={:compact}
          class="font-mono text-xs"
          placeholder="e.g. cassandra.repair or linux.*"
          disabled={!@can_manage}
        />
      </div>
      <div class="sm:col-span-2">
        <.input
          name={"policy[overrides][#{@index}][decision]"}
          type="select"
          label="Decision"
          label_variant={:eyebrow}
          size={:compact}
          class="text-xs"
          value={@override["decision"]}
          options={decision_options()}
          disabled={!@can_manage}
        />
      </div>
      <%!-- Trash sits right after Decision (justify-start), not floated to the
           far edge of its cell. h-7 matches the compact text-xs input's 28px box so,
           bottom-aligned (items-end), the icon lines up with the Decision select
           instead of overhanging it. --%>
      <div class="sm:col-span-1 sm:flex sm:items-end sm:justify-start">
        <.icon_button
          :if={@can_manage}
          icon="hero-trash"
          label="Remove override"
          tone={:rose}
          phx-click="remove_override"
          phx-value-editor={@editor_id}
          phx-value-index={@index}
          class="grid h-7 w-7 place-items-center"
        />
      </div>
    </div>

    <%!-- A dead rule (its glob is covered by an earlier one) — advisory, not
         blocking. `shadowed_by` is the 0-based index of the earlier rule, so
         +1 for the operator's 1-based count. Sharpen the copy for a deny:
         that's the case where the operator believes they blocked something. --%>
    <p
      :if={@shadowed_by != nil}
      class="mt-2 flex items-start gap-1.5 text-xs text-amber-300"
    >
      <.icon name="hero-exclamation-triangle-mini" class="mt-0.5 h-3.5 w-3.5 flex-none" />
      <span :if={@override["decision"] == "deny"}>
        Shadowed by rule {@shadowed_by + 1} above — this <strong>deny</strong>
        never applies (first match wins).
      </span>
      <span :if={@override["decision"] != "deny"}>
        Shadowed by rule {@shadowed_by + 1} above — this rule never applies (first match wins).
      </span>
    </p>
    """
  end

  defp decision_options,
    do: [{"Allow", "allow"}, {"Require approval", "require_approval"}, {"Deny", "deny"}]

  # The index of the earlier override that shadows the row at `index`, or nil.
  # Derived from the live (possibly-unsaved) rows via the pure `Policies`
  # accessor — first-match means an override under a broader earlier glob is
  # dead.
  defp shadowed_by(overrides, index) do
    %{"overrides" => overrides}
    |> Policies.shadowed_overrides()
    |> Enum.find_value(fn %{index: i, shadowed_by: j} -> if i == index, do: j end)
  end

  # The rank below which a tier's decision can't drop: 0 for `low` (anything
  # goes), otherwise the rank of the immediately-lower tier. Reads the lower
  # tier directly because the state is already monotonized.
  defp tier_floor_rank(_defaults, "low"), do: 0
  defp tier_floor_rank(defaults, "medium"), do: Policies.decision_rank(defaults["low"])
  defp tier_floor_rank(defaults, "high"), do: Policies.decision_rank(defaults["medium"])
  defp tier_floor_rank(defaults, "critical"), do: Policies.decision_rank(defaults["high"])
end
