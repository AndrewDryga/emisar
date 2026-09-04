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

  # Non-breaking spaces so the browser keeps the indent (ASCII whitespace in an
  # <option> is stripped) — nests runners under their group in the target picker.
  @runner_indent "    "

  def mount(_params, _session, socket) do
    socket =
      assign(socket, page_title: "Policy", loading?: not connected?(socket), load_error?: false)

    # Gate BEFORE any policy read: a role without view_policies must see
    # nothing, not the account posture with only the scoped read errored.
    cond do
      not Policies.subject_can_view_policies?(socket.assigns.current_subject) ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to policies.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}")}

      connected?(socket) ->
        {:ok, load_all(socket)}

      true ->
        {:ok, socket}
    end
  end

  # Load every editor the page needs: the default (account-scoped) policy, the existing
  # runner/group rulesets, and the runner/group pickers new rulesets target.
  defp load_all(socket) do
    subject = socket.assigns.current_subject
    capabilities = Policies.policy_management_capabilities(subject)
    {runners, runners_failed?} = list_runners(subject)
    {groups, groups_failed?} = list_groups(subject)
    catalog_index = load_action_risk_index(subject)

    account_policy =
      case Policies.fetch_policy(subject) do
        {:ok, policy} -> policy
        {:error, _} -> nil
      end

    account_editor =
      account_policy |> build_account_editor() |> Map.put(:catalog, catalog_index.account)

    # A failed scoped-policy read must read as an error, not an empty ruleset
    # list — "No targeted rulesets yet" would wrongly imply none are configured.
    {rulesets, load_error?} =
      case Policies.list_scoped_policies(subject) do
        {:ok, policies} ->
          {Enum.map(policies, fn policy ->
             policy |> build_ruleset_editor() |> put_ruleset_catalog(runners, catalog_index)
           end), false}

        {:error, _} ->
          {[], true}
      end

    socket
    |> assign(:loading?, false)
    |> assign(:load_error?, load_error?)
    |> assign(:can_manage?, capabilities.can_manage?)
    |> assign(:has_runner_access?, capabilities.has_runner_access?)
    |> assign(:can_manage_scoped?, capabilities.can_manage_scoped?)
    |> assign(:can_manage_account?, capabilities.can_manage_account?)
    |> assign(:catalog_index, catalog_index)
    |> assign(:account, account_editor)
    |> assign(:rulesets, rulesets)
    |> assign(:runners, runners)
    |> assign(:groups, groups)
    |> assign(:targets_error?, runners_failed? or groups_failed?)
  end

  # The compact catalog risk index every policy rail derives from. A failed read
  # is an empty index (the rails show the connect-a-runner hint), never a crash.
  defp load_action_risk_index(subject) do
    case Catalog.action_risk_index_for_account(subject) do
      {:ok, index} -> index
      {:error, _} -> empty_action_risk_index()
    end
  end

  defp empty_action_risk_index, do: %{account: %{}, runners: %{}}

  # The target catalog a ruleset governs (its runner, or its group's runners) —
  # so the rail speaks for THAT target, not account-wide. A group resolves to its
  # runners' ids from the already-loaded @runners.
  defp put_ruleset_catalog(ruleset, runners, catalog_index) do
    catalog = Catalog.action_risks_from_index(catalog_index, ruleset_runner_ids(ruleset, runners))
    Map.put(ruleset, :catalog, catalog)
  end

  defp ruleset_runner_ids(%{scope_type: :runner, scope_value: runner_id}, _runners),
    do: [runner_id]

  defp ruleset_runner_ids(%{scope_type: :group, scope_value: group}, runners),
    do: runners |> Enum.filter(&(&1.group == group)) |> Enum.map(& &1.id)

  defp ruleset_runner_ids(_ruleset, _runners), do: []

  defp build_account_editor(policy) do
    rules = (policy && policy.rules) || Policies.default_rules()
    input = Policies.editor_input(rules)

    Map.merge(input, %{
      uid: "account",
      scope_type: :account,
      scope_value: "",
      show_override_errors?: false,
      # Snapshot of the saved rules: editor_dirty?/1 compares the live edits to
      # this, so reverting a change back clears the Save button (not a one-way flag).
      baseline_rules: stored_baseline(policy, input),
      policy: policy,
      rules_errors: []
    })
  end

  defp build_ruleset_editor(%Policies.Policy{} = policy) do
    input = Policies.editor_input(policy.rules || Policies.default_rules())

    Map.merge(input, %{
      uid: policy.id,
      scope_type: policy.scope_type,
      scope_value: policy.scope_value,
      show_override_errors?: false,
      baseline_rules: stored_baseline(policy, input),
      policy: policy,
      rules_errors: []
    })
  end

  # A blank, not-yet-targeted ruleset, seeded from the default policy so the
  # operator tweaks the live posture rather than starting from an empty one —
  # important under replace-semantics, where a ruleset that dropped the
  # account's deny-overrides would silently widen access for that target.
  defp new_ruleset(account) do
    input = policy_input(account)

    Map.merge(input, %{
      uid: "new-" <> Integer.to_string(System.unique_integer([:positive])),
      scope_type: nil,
      scope_value: "",
      show_override_errors?: false,
      baseline_rules: Policies.build_rules(input),
      # Filled in once a target is picked (set_target); no target = no catalog.
      catalog: %{},
      policy: nil,
      rules_errors: []
    })
  end

  defp stored_baseline(nil, input), do: Policies.build_rules(input)
  defp stored_baseline(%Policies.Policy{rules: rules}, _input), do: rules

  # The targets a ruleset can claim. A failed read is carried, not collapsed:
  # empty target lists otherwise disable Add ruleset with "…or none exist yet",
  # blaming an empty fleet for a read that never answered.
  defp list_runners(subject) do
    case Runners.list_all_runners_for_account(subject) do
      {:ok, runners} -> {runners, false}
      {:error, _} -> {[], true}
    end
  end

  defp list_groups(subject) do
    case Runners.list_group_summaries(subject) do
      {:ok, rows} ->
        {rows |> Enum.map(&elem(&1, 0)) |> Enum.reject(&blank?/1) |> Enum.sort(), false}

      {:error, _} ->
        {[], true}
    end
  end

  # -- Events ---------------------------------------------------------

  def handle_event("form_change", %{"editor" => editor_id, "policy" => params}, socket),
    do: {:noreply, apply_policy_params(socket, editor_id, params)}

  # A crafted event that drops a required key would otherwise match no clause
  # and crash the socket, taking the page's unsaved state with it. Every
  # mutating handler on this page ends in this no-op.
  def handle_event("form_change", _params, socket), do: {:noreply, socket}

  def handle_event("add_override", %{"editor" => editor_id}, socket) do
    {:noreply,
     update_editor(socket, editor_id, fn editor ->
       %{editor | overrides: editor.overrides ++ [Policies.empty_override()]}
     end)}
  end

  def handle_event("add_override", _params, socket), do: {:noreply, socket}

  def handle_event("remove_override", %{"editor" => editor_id, "index" => idx}, socket)
      when is_binary(editor_id) and is_binary(idx) do
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

  def handle_event("remove_override", _params, socket), do: {:noreply, socket}

  def handle_event("add_ruleset", _params, socket) do
    if Policies.subject_can_manage_scoped_policies?(socket.assigns.current_subject) do
      {:noreply,
       assign(
         socket,
         :rulesets,
         socket.assigns.rulesets ++ [new_ruleset(socket.assigns.account)]
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_target", %{"uid" => uid, "target" => target}, socket)
      when is_binary(uid) and is_binary(target) do
    {scope_type, scope_value} = parse_target(target)

    {:noreply,
     update_editor(socket, uid, fn editor ->
       editor = %{editor | scope_type: scope_type, scope_value: scope_value}
       put_ruleset_catalog(editor, socket.assigns.runners, socket.assigns.catalog_index)
     end)}
  end

  def handle_event("set_target", _params, socket), do: {:noreply, socket}

  def handle_event("remove_ruleset", %{"uid" => uid}, socket) do
    case find_ruleset(socket, uid) do
      # Saved ruleset — deleting it is a real mutation, so gate + audit.
      %{policy: %Policies.Policy{} = policy} ->
        Permissions.gated(
          socket,
          Policies.subject_can_manage_scoped_policies?(socket.assigns.current_subject),
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

  def handle_event("remove_ruleset", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"editor" => editor_id} = params, socket) do
    Permissions.gated(
      socket,
      subject_can_save_editor?(socket.assigns.current_subject, editor_id),
      fn socket ->
        socket = apply_policy_params(socket, editor_id, params["policy"])
        save_editor(socket, get_editor(socket, editor_id))
      end
    )
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  defp subject_can_save_editor?(subject, "account"),
    do: Policies.subject_can_manage_account_policy?(subject)

  defp subject_can_save_editor?(subject, _editor_id),
    do: Policies.subject_can_manage_scoped_policies?(subject)

  defp save_editor(socket, %{scope_type: :account} = editor),
    do: persist(socket, editor, &Policies.save_rules/2)

  # Scope ownership is the context's call: `Policies.save_scoped_rules/4` rejects
  # a runner or group outside the subject's own fleet (a crafted `set_target`
  # event can carry either — IL-15); `persist_rules` maps the denial.
  defp save_editor(socket, %{scope_type: scope_type, scope_value: value} = editor)
       when scope_type in [:runner, :group] and is_binary(value) and value != "" do
    persist(socket, editor, fn rules, subject ->
      Policies.save_scoped_rules(rules, scope_type, value, subject)
    end)
  end

  defp save_editor(socket, _editor),
    do: {:noreply, put_flash(socket, :error, "Choose a runner or group for this ruleset first.")}

  defp persist(socket, editor, save_fun) do
    if Enum.any?(editor.overrides, &partial_override?/1) do
      {:noreply,
       update_editor(socket, editor.uid, fn editor ->
         %{editor | show_override_errors?: true}
       end)}
    else
      persist_rules(socket, editor, save_fun)
    end
  end

  defp persist_rules(socket, editor, save_fun) do
    rules = Policies.build_rules(policy_input(editor))

    case save_fun.(rules, socket.assigns.current_subject) do
      {:ok, policy} ->
        {:noreply,
         socket |> put_flash(:info, "Policy saved.") |> replace_saved(editor.uid, policy)}

      # The UI prevents invalid policies (constrained selects + monotonic
      # enforcement + partial rows blocked + untouched blank rows dropped), so
      # this is a defensive net: show the rules-level error inline on the card
      # it belongs to, not a flash.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         update_editor(socket, editor.uid, fn editor ->
           %{editor | rules_errors: changeset_rules_errors(changeset)}
         end)}

      {:error, :runner_not_found} ->
        {:noreply, put_flash(socket, :error, "That runner isn't in your fleet.")}

      {:error, :group_not_found} ->
        {:noreply, put_flash(socket, :error, "That group isn't in your fleet.")}

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
      |> put_ruleset_catalog(socket.assigns.runners, socket.assigns.catalog_index)

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

  defp rules_changed?(editor) do
    Enum.any?(editor.overrides, &partial_override?/1) or
      Policies.build_rules(policy_input(editor)) != editor.baseline_rules
  end

  # The browser adapter: the form posts overrides as an index-keyed map and the
  # approval gate as strings, so translate both into the domain's shape and let
  # `Policies` own what an edit may change.
  defp apply_policy_params(socket, editor_id, params) when is_map(params) do
    update_editor(socket, editor_id, fn editor ->
      changes = %{
        defaults: params["defaults"] || %{},
        overrides: normalize_indexed(params["overrides"] || []),
        approval: parse_approval(editor.approval, params["approval"] || %{})
      }

      input = Policies.update_editor_input(policy_input(editor), changes)

      editor |> Map.merge(input) |> Map.put(:rules_errors, rules_errors(input))
    end)
  end

  defp apply_policy_params(socket, _editor_id, _params), do: socket

  # The domain-shaped slice of an editor (or of a rail's assigns) — `Policies`
  # owns the rules; every other key on the map is this page's own state.
  defp policy_input(state),
    do: Map.take(state, [:defaults, :overrides, :approval])

  defp parse_target(target) do
    case String.split(target, ":", parts: 2) do
      ["runner", id] -> {:runner, id}
      ["group", name] -> {:group, name}
      _ -> {nil, ""}
    end
  end

  # The choice cards post an explicit boolean string. Treat a missing value as
  # false, and floor the number input at 1 to mirror the changeset.
  defp parse_approval(current, form) when is_map(form) do
    %{
      "min_approvals" => parse_min_approvals(form["min_approvals"], current["min_approvals"]),
      "allow_self_approval" => form["allow_self_approval"] == "true"
    }
  end

  defp parse_approval(current, _form), do: current

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
    fewer_approvals =
      if scoped["min_approvals"] < default["min_approvals"],
        do: [
          "requires fewer approvals (#{scoped["min_approvals"]} vs #{default["min_approvals"]})"
        ],
        else: []

    self_approval =
      if scoped["allow_self_approval"] and not default["allow_self_approval"],
        do: ["lets the requester approve their own action"],
        else: []

    fewer_approvals ++ self_approval
  end

  # A "require approval" gate that adds no SECOND party — one approval needed and
  # the requester may supply it.
  defp single_reviewer_gate?(approval),
    do: approval["allow_self_approval"] && approval["min_approvals"] == 1

  # Singular when exactly one approval is required — "1 distinct operators" is wrong,
  # and "distinct" is meaningless for a single approver (nothing to be distinct from).
  defp approval_operators_noun(min_approvals) do
    if min_approvals == 1, do: "operator", else: "distinct operators"
  end

  defp weakening_sentence([one]), do: one
  defp weakening_sentence(many), do: Enum.join(many, " and ")

  # LiveView posts a repeated field group as an index-keyed map; the domain
  # takes an ordered list.
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

  defp rules_errors(input) do
    input
    |> Policies.build_rules()
    |> Policies.change_policy()
    |> changeset_rules_errors()
  end

  defp changeset_rules_errors(changeset),
    do: for({:rules, {msg, _opts}} <- changeset.errors, do: msg)

  defp partial_override?(override) do
    blank_action?(override) and
      (not blank?(override["name"]) or override["decision"] != "allow")
  end

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

  defp can_add_ruleset?(runners, groups, rulesets, targets_error?),
    do: not targets_error? and addable_any?(runners, groups, rulesets)

  defp add_ruleset_disabled_reason(_runners, _groups, _rulesets, true),
    do: "Couldn't load the runners and groups a ruleset targets. Refresh the page to try again"

  defp add_ruleset_disabled_reason(runners, groups, rulesets, false) do
    if not addable_any?(runners, groups, rulesets),
      do: "Every runner and group already has a ruleset (or none exist yet)"
  end

  # -- Render ---------------------------------------------------------

  # No-op for the broadcasts the on_mount badge/fleet hooks forward (approvals,
  # pack trust, runner presence). The hooks own those nav cues; this page ignores them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.console_shell
      chrome={@shell_chrome}
      current_membership={@current_membership}
      current_subject={@current_subject}
      current_user={@current_user}
      current_account={@current_account}
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
            <.doc_link href={~p"/docs/policies-and-approvals"}>Policy docs</.doc_link>
          </.page_intro>

          <%!-- A quiet naked line, not a boxed note — the viewer fact isn't an
               actionable warning (§8.1). --%>
          <p :if={not @has_runner_access?} class="text-xs text-zinc-400">
            No runners in your access. The default policy is read-only, and targeted rulesets are hidden.
          </p>
          <p :if={@has_runner_access? and not @can_manage?} class="text-xs text-zinc-400">
            You can view the policy, but only owners and admins can change it.
          </p>
          <p
            :if={@has_runner_access? and @can_manage? and not @can_manage_scoped?}
            class="text-xs text-zinc-400"
          >
            Policy rules can affect every pack on their target. Full pack access is required to change them.
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
              <%= if @has_runner_access? do %>
                The base decision for every runner, by risk tier — unless a targeted ruleset below overrides it.
              <% else %>
                The base decision for every runner, by risk tier.
              <% end %>
            </:subtitle>
            <%!-- Navigation, but the SAME verb repeats on every targeted-ruleset
                 header below, where the Remove peer forces the bordered face —
                 and one repeated verb wears ONE face per page (the founder read
                 the mixed faces as the rulesets lacking the affordance). --%>
            <:actions :if={@account.policy}>
              <.button
                navigate={
                  ~p"/app/#{@current_account}/audit?#{[target_kind: "policy", target_id: @account.policy.id]}"
                }
                variant={:secondary}
                size={:lg}
                class="h-10"
              >
                View activity
              </.button>
            </:actions>
          </.section_header>

          <p
            :if={@can_manage_scoped? and not @can_manage_account?}
            class="mb-4 text-xs text-zinc-400"
          >
            The default applies to every runner. Full runner access is required to change it.
          </p>

          <div class="grid grid-cols-1 gap-8 lg:grid-cols-4 lg:items-start">
            <div class="lg:col-span-3">
              <.policy_fields
                editor_id="account"
                defaults={@account.defaults}
                overrides={@account.overrides}
                catalog={@account.catalog}
                approval={@account.approval}
                rules_errors={@account.rules_errors}
                show_override_errors={@account.show_override_errors?}
                can_manage={@can_manage_account?}
                save_label="Save default policy"
                dirty={editor_dirty?(@account)}
                top_margin="mt-0"
              />
            </div>
            <aside class="lg:col-span-1">
              <.policy_rail
                editor_id="account"
                catalog={@account.catalog}
                defaults={@account.defaults}
                overrides={@account.overrides}
                approval={@account.approval}
                catalog_path={~p"/app/#{@current_account}/packs"}
                catalog_visible?={@has_runner_access?}
                target="your fleet"
              />
            </aside>
          </div>
        </section>

        <section :if={@has_runner_access?}>
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
            icon="state.warning"
            title="Couldn't load targeted rulesets"
          >
            This is a load error, not an empty configuration — rulesets may well be set.
            Refresh the page; if it persists, your access to this account may have changed.
          </.empty_state>

          <%!-- Viewer with nothing to see gets the quiet fact; for a manager
               the Add-ruleset composer below IS the empty state (the runbook
               precedent — no dashed hint above a dashed composer). --%>
          <p
            :if={not @load_error? and @rulesets == [] and not @can_manage_scoped?}
            class="text-sm text-zinc-400"
          >
            No targeted rulesets — every runner uses the default policy above.
          </p>

          <div :if={@rulesets != []} class="space-y-8">
            <div :for={ruleset <- @rulesets}>
              <.ruleset_unit
                ruleset={ruleset}
                current_account={@current_account}
                account_approval={@account.approval}
                runners={@runners}
                groups={@groups}
                rulesets={@rulesets}
                can_manage={@can_manage_scoped?}
                catalog_path={~p"/app/#{@current_account}/packs"}
              />
            </div>
          </div>

          <div
            :if={@can_manage_scoped? and not @load_error?}
            id="add-ruleset-row"
            class={["grid grid-cols-1 gap-8 lg:grid-cols-4", @rulesets != [] && "mt-8"]}
          >
            <div id="add-ruleset-control" class="lg:col-span-3">
              <.add_row
                label="Add ruleset"
                phx-click="add_ruleset"
                disabled={not can_add_ruleset?(@runners, @groups, @rulesets, @targets_error?)}
              />
              <p
                :if={not can_add_ruleset?(@runners, @groups, @rulesets, @targets_error?)}
                id="add-ruleset-disabled-reason"
                class="mt-2 text-xs text-zinc-400"
              >
                {add_ruleset_disabled_reason(
                  @runners,
                  @groups,
                  @rulesets,
                  @targets_error?
                )}
              </p>
            </div>
          </div>
        </section>
      </div>
    </.console_shell>
    """
  end

  attr :catalog, :map, required: true, doc: "%{action_id => risk} the policy governs"
  attr :editor_id, :string, required: true
  attr :defaults, :map, required: true
  attr :overrides, :list, required: true
  attr :approval, :map, required: true
  attr :catalog_path, :string, required: true, doc: "link to the full action catalog (Packs)"
  attr :catalog_visible?, :boolean, default: true

  attr :target, :string,
    required: true,
    doc: "who this policy applies to, e.g. \"your fleet\" or a group name"

  # The side rail: apply the LIVE rules to the target's catalog and preview the
  # decision — allow / needs-approval / deny, with a few example actions — so the
  # operator sees what the policy DOES, live as they edit. Below it, the catalog's
  # risk profile. Recomputes on every render (pure, in-memory).
  defp policy_rail(assigns) do
    rules = Policies.build_rules(policy_input(assigns))

    assigns =
      assign(assigns,
        outcome: Policies.simulate_outcome(rules, assigns.catalog),
        breakdown: Catalog.risk_breakdown_of(assigns.catalog),
        single_reviewer?: single_reviewer_gate?(assigns.approval),
        total: map_size(assigns.catalog)
      )

    ~H"""
    <div id={"policy-rail-" <> @editor_id} class="space-y-5">
      <div>
        <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">In effect</h3>
        <p :if={@total > 0} class="mt-1 text-xs leading-relaxed text-zinc-400">
          What this policy decides for {@target}'s
          <span class="font-medium text-zinc-300">{@total}</span>
          {ngettext_action(@total)}.
        </p>
        <%!-- No catalog yet: the empty note stands in as the subtitle — no
             "…for your fleet's 0 actions." line to state a count of nothing. --%>
        <p
          :if={@total == 0 and not @catalog_visible?}
          class="mt-1 text-xs leading-relaxed text-zinc-400"
        >
          No action catalog is visible without runner access.
        </p>
        <p
          :if={@total == 0 and @catalog_visible?}
          class="mt-1 text-xs leading-relaxed text-zinc-400"
        >
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
          <h3 class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
            Catalog by risk
          </h3>
          <.link
            href={@catalog_path}
            target="_blank"
            class="inline-flex items-center gap-0.5 text-[10px] font-medium text-zinc-400 hover:text-zinc-300"
          >
            View all <.icon name="action.external_link" class="h-2.5 w-2.5" />
          </.link>
        </div>
        <dl class="mt-3 space-y-2">
          <div
            :for={tier <- ["critical", "high", "medium", "low"]}
            class="flex items-center justify-between"
          >
            <dt>
              <.risk_pill id={"policy-breakdown-#{tier}-risk"} risk={tier} variant={:track} />
            </dt>
            <dd class="text-xs tabular-nums text-zinc-400">{@breakdown[tier]}</dd>
          </div>
        </dl>
      </div>

      <div
        :if={@single_reviewer?}
        id={"policy-single-reviewer-warning-#{@editor_id}"}
        class="border-t border-zinc-800/70 pt-4"
      >
        <.single_reviewer_warning />
      </div>
    </div>
    """
  end

  # The effective-state rail is the warning's one home. The approval controls
  # already show the selected posture; repeating the consequence there makes
  # the same warning compete with itself on the page.
  defp single_reviewer_warning(assigns) do
    ~H"""
    <.event_block
      tone={:amber}
      icon="security.posture_warning"
      title="In effect — a single approval is enough, and the requester may approve their own request"
      size={:compact}
    >
      <:body>Choose a different operator, or raise the count, to add independent review.</:body>
    </.event_block>
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
        class="mt-1 truncate pl-4 font-mono text-[10px] text-zinc-400"
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
  attr :current_account, :map, required: true
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
              <p class="mt-1 text-xs text-zinc-400">
                Replaces the default policy for this {@ruleset.scope_type}.
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-3">
              <%!-- Navigation, but it shares this header row with the bordered
                   Remove — one button grammar per row, at the peer's optical
                   height (§7.47). --%>
              <.button
                navigate={
                  ~p"/app/#{@current_account}/audit?#{[target_kind: "policy", target_id: @ruleset.policy.id]}"
                }
                variant={:secondary}
                size={:lg}
                class="h-10"
              >
                View activity
              </.button>
              <.confirm_button
                :if={@can_manage}
                id={"remove-ruleset-#{@ruleset.uid}"}
                title="Remove this ruleset?"
                confirm_label="Remove ruleset"
                variant={:secondary}
                tone={:rose}
                size={:lg}
                icon="action.delete"
                class="h-10"
                on_confirm={JS.push("remove_ruleset", value: %{uid: @ruleset.uid})}
              >
                <:body>This {@ruleset.scope_type} falls back to the default policy.</:body>
                Remove
              </.confirm_button>
            </div>
          </header>
        <% else %>
          <%!-- Unsaved ruleset: the target picker with a red Remove aligned to the
           select box (items-end + matching size). Nothing's persisted, so Remove
           drops the card directly — no confirm modal. A form (not a lone select)
           carries the uid as a hidden field on the change event. --%>
          <header class="flex items-end gap-3">
            <form
              id={"policy-target-form-#{@ruleset.uid}"}
              phx-change="set_target"
              class="w-full sm:max-w-xs"
            >
              <input type="hidden" name="uid" value={@ruleset.uid} />
              <%!-- One tree: each group is a selectable header with its runners
               indented beneath it. A native <optgroup> label can't be picked,
               so groups are plain options; a target another ruleset already
               claims is shown disabled. --%>
              <.select
                id={"policy-target-#{@ruleset.uid}"}
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
              icon="action.delete"
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
          catalog={@ruleset.catalog}
          approval={@ruleset.approval}
          approval_weakenings={approval_weakenings(@ruleset.approval, @account_approval)}
          rules_errors={@ruleset.rules_errors}
          show_override_errors={@ruleset.show_override_errors?}
          can_manage={@can_manage}
          save_label="Save ruleset"
          dirty={editor_dirty?(@ruleset)}
        />
        <p :if={is_nil(@ruleset.scope_type)} class="mt-4 text-xs text-zinc-400">
          Pick a runner or group above, then set its rules.
        </p>
      </div>
      <aside :if={@ruleset.scope_type} class="lg:col-span-1">
        <.policy_rail
          editor_id={@ruleset.uid}
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

  attr :catalog, :map,
    required: true,
    doc: "the target's `%{action_id => risk}` index — what an override glob is checked against"

  attr :approval, :map, required: true

  attr :approval_weakenings, :list,
    default: [],
    doc: "ways this scoped gate is laxer than the account default (empty for the default itself)"

  attr :rules_errors, :list, required: true
  attr :show_override_errors, :boolean, required: true
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
    assigns =
      assign(assigns,
        shadowed_overrides: shadowed_overrides_by_index(assigns.overrides),
        unmatched_overrides: unmatched_overrides_by_index(assigns.overrides, assigns.catalog),
        single_reviewer?: single_reviewer_gate?(assigns.approval)
      )

    ~H"""
    <%!-- Each policy — the default and every targeted ruleset — is a dashed
         card (the runbook-editor section grammar). A dashed frame with no wash
         is the sanctioned placeholder shape, not a solid island (§8.1). --%>
    <%!-- `@container`: this card sits beside a rail, so its own width — not the
         viewport's — decides how many tier tracks fit. Keyed to the viewport, a
         1024px window put four selects in a 509px card and clipped "Require
         approval" against its chevron. --%>
    <form
      id={"policy-form-" <> @editor_id}
      phx-change="form_change"
      phx-submit="save"
      class={[
        @top_margin,
        "@container space-y-8 rounded-xl border border-dashed border-zinc-800 p-5 sm:p-6"
      ]}
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
        <div class="grid grid-cols-1 gap-x-4 gap-y-4 @md:grid-cols-2 @2xl:grid-cols-4">
          <.tier_field
            :for={tier <- ["low", "medium", "high", "critical"]}
            editor_id={@editor_id}
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
        <p class="mt-0.5 text-xs text-zinc-400">
          First match wins. Action supports wildcards (e.g. <code class="font-mono text-zinc-300">cassandra.*</code>).
        </p>

        <%!-- Viewer's empty fact; a manager's empty state IS the composer below. --%>
        <p :if={@overrides == [] and not @can_manage} class="mt-4 text-xs text-zinc-400">
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
              shadowed_by={Map.get(@shadowed_overrides, idx)}
              unmatched={MapSet.member?(@unmatched_overrides, idx)}
              show_error={@show_override_errors}
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
           group them was one more island). The brand ring marks the active input;
           the neutral card surface and check avoid turning that choice into a safe
           verdict. The verdict below resolves who + count into English. --%>
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
          <:card value="false" icon="identity.group" title="A different operator">
            No signing off on your own request.
          </:card>
          <:card value="true" icon="identity.person" title="Anyone, incl. requester">
            The requester's own approval can count.
          </:card>
        </.choice_cards>

        <div class="mt-6">
          <.label variant={:eyebrow} for={"policy-#{@editor_id}-min-approvals"}>
            Required approvals
          </.label>
          <%!-- The eyebrow labels from above; the input and the trailing clause
               share one centered row so they align — an inline eyebrow beside the
               input never lined up with the trailing text. --%>
          <div class="mt-2 flex items-center gap-x-2.5">
            <input
              type="number"
              id={"policy-#{@editor_id}-min-approvals"}
              name="policy[approval][min_approvals]"
              value={@approval["min_approvals"]}
              min="1"
              max={Policies.max_min_approvals()}
              step="1"
              disabled={!@can_manage}
              class="w-14 rounded-lg border-0 bg-zinc-900 px-2 py-1.5 text-center text-sm font-medium text-zinc-100 ring-1 ring-inset ring-zinc-800 focus:ring-2 focus:ring-inset focus:ring-brand-500 disabled:opacity-50"
            />
            <span class="text-xs text-zinc-400">
              {approval_operators_noun(@approval["min_approvals"])}, before the action runs.
            </span>
          </div>
        </div>

        <%!-- A scoped ruleset REPLACES the default wholesale, so an override
             seeded from a pre-gate template can silently weaken the approval
             gate for its target. Nudge the operator when that's the case. --%>
        <.event_block
          :if={@approval_weakenings != []}
          tone={:amber}
          icon="security.posture_warning"
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

  attr :editor_id, :string,
    required: true,
    doc: "scopes the lock tooltip id — unique per policy card"

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
        id={"tier-lock-#{@editor_id}-#{@tier}"}
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

  attr :unmatched, :boolean,
    required: true,
    doc: "no action in the target's catalog matches this glob — advisory, never blocking"

  attr :show_error, :boolean, required: true
  attr :can_manage, :boolean, required: true

  # A NAKED override row — compact fields in the runbook-editor grid grammar,
  # a hairline between rows; the wash box around each row was an island.
  defp override_row(assigns) do
    ~H"""
    <%!-- Name and action share the flexible width; Decision takes a `max-content`
         track, so the select is always exactly as wide as its longest option
         needs and a new decision label can never clip it. The trailing track is
         a FIXED trash width, not `auto` — a view-only row renders no trash, and
         a content-sized track would collapse there, sliding every field sideways
         between the editable and blocked states. It reserves the icon button's
         full 40px target even though its visible face matches the 32px fields. --%>
    <div class={[
      "space-y-2 @md:grid @md:items-start @md:gap-2 @md:space-y-0",
      "@md:grid-cols-[minmax(0,3fr)_minmax(0,5fr)_max-content_2.5rem]"
    ]}>
      <div>
        <.input
          id={"policy-#{@editor_id}-override-#{@index}-name"}
          name={"policy[overrides][#{@index}][name]"}
          value={@override["name"]}
          label="Name"
          label_variant={:eyebrow}
          size={:compact}
          placeholder="optional"
          disabled={!@can_manage}
        />
      </div>
      <div>
        <.input
          id={"policy-#{@editor_id}-override-#{@index}-action"}
          name={"policy[overrides][#{@index}][action]"}
          value={@override["action"]}
          label="Action (glob ok)"
          label_variant={:eyebrow}
          size={:compact}
          class="font-mono text-xs"
          placeholder="e.g. cassandra.repair or linux.*"
          errors={override_action_errors(@show_error, @override)}
          disabled={!@can_manage}
        />
      </div>
      <div>
        <.input
          id={"policy-#{@editor_id}-override-#{@index}-decision"}
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
           far edge of its cell. pt-4 centers the 40px target on the compact
           field box; its 32px visual face aligns exactly with that box. --%>
      <div class="@md:flex @md:items-start @md:justify-start @md:pt-4">
        <.icon_button
          :if={@can_manage}
          icon="action.delete"
          label="Remove override"
          tone={:rose}
          size={:compact}
          phx-click="remove_override"
          phx-value-editor={@editor_id}
          phx-value-index={@index}
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
      <.icon name="state.warning" class="mt-0.5 h-3.5 w-3.5 flex-none" />
      <span :if={@override["decision"] == "deny"}>
        Shadowed by rule {@shadowed_by + 1} above — this <strong>deny</strong>
        never applies (first match wins).
      </span>
      <span :if={@override["decision"] != "deny"}>
        Shadowed by rule {@shadowed_by + 1} above — this rule never applies (first match wins).
      </span>
    </p>

    <%!-- A glob that matches nothing today. Not an error: the pack may simply
         not be installed yet. Shown only when the row isn't already shadowed,
         so one row carries one diagnosis. Sharpened for a deny, where the
         operator believes the fleet is covered and it isn't. --%>
    <p
      :if={@unmatched and @shadowed_by == nil}
      class="mt-2 flex items-start gap-1.5 text-xs text-amber-300"
    >
      <.icon name="state.warning" class="mt-0.5 h-3.5 w-3.5 flex-none" />
      <span :if={@override["decision"] == "deny"}>
        Matches no action on this target — this <strong>deny</strong>
        blocks nothing today. Check the glob, or ignore this if the pack isn't installed yet.
      </span>
      <span :if={@override["decision"] != "deny"}>
        Matches no action on this target. Check the glob, or ignore this if the pack isn't
        installed yet.
      </span>
    </p>
    """
  end

  defp override_action_errors(true, override) do
    if partial_override?(override),
      do: ["Enter an action glob or remove this override."],
      else: []
  end

  defp override_action_errors(false, _override), do: []

  defp decision_options,
    do: [{"Allow", "allow"}, {"Require approval", "require_approval"}, {"Deny", "deny"}]

  # The index of the earlier override that shadows each row, keyed by the
  # shadowed row's index. Derived once per editor render from the live
  # (possibly-unsaved) rows via the pure `Policies` accessor — first-match means
  # an override under a broader earlier glob is dead.
  defp shadowed_overrides_by_index(overrides) do
    %{"overrides" => overrides}
    |> Policies.shadowed_overrides()
    |> Map.new(fn %{index: index, shadowed_by: shadowed_by} -> {index, shadowed_by} end)
  end

  # Rows whose glob matches nothing in the target's catalog. Same live rows and
  # same matcher dispatch uses, so what the editor warns about is what the fleet
  # would actually do. Empty while the catalog is still empty.
  defp unmatched_overrides_by_index(overrides, catalog) do
    %{"overrides" => overrides}
    |> Policies.unmatched_overrides(catalog)
    |> MapSet.new(& &1.index)
  end

  # The rank below which a tier's decision can't drop: 0 for `low` (anything
  # goes), otherwise the rank of the immediately-lower tier. Reads the lower
  # tier directly because the state is already monotonized.
  defp tier_floor_rank(_defaults, "low"), do: 0
  defp tier_floor_rank(defaults, "medium"), do: Policies.decision_rank(defaults["low"])
  defp tier_floor_rank(defaults, "high"), do: Policies.decision_rank(defaults["medium"])
  defp tier_floor_rank(defaults, "critical"), do: Policies.decision_rank(defaults["high"])
end
