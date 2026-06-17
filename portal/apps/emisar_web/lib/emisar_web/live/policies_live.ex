defmodule EmisarWeb.PoliciesLive do
  @moduledoc """
  Policy editor. One page, everything live-editable:

    * **Default policy** — the base (the account-scoped policy, `scope_type:
      :account`, labeled "Default policy" in the UI). Risk-tier defaults +
      per-action overrides. Applies to every runner.
    * **Targeted rulesets** — an inline list of per-runner / per-group
      policies. Add one, pick a runner or group, edit its rules. A ruleset
      **replaces** the default policy for that target (most specific wins:
      runner > group > account), it doesn't layer on top — so what a card
      shows is exactly what runs there.

  Each card is its own form with its own Save (a scoped ruleset is its own
  policy row, version, and audit entry). Events carry an `editor`
  discriminator — `"account"` or a ruleset uid — so one set of handlers
  drives every card.
  """
  use EmisarWeb, :live_view

  alias Emisar.Policies
  alias Emisar.Runners
  alias EmisarWeb.Permissions

  @decisions Policies.decisions()
  @tiers Policies.risk_tiers()

  # Non-breaking spaces so the browser keeps the indent (ASCII whitespace in an
  # <option> is stripped) — nests runners under their group in the target picker.
  @runner_indent "    "

  def mount(_params, _session, socket) do
    socket = assign(socket, page_title: "Policy", loading?: not connected?(socket))
    {:ok, if(connected?(socket), do: load_all(socket), else: socket)}
  end

  # Load every editor the page needs: the default (account-scoped) policy, the existing
  # runner/group rulesets, and the runner/group pickers new rulesets target.
  defp load_all(socket) do
    subject = socket.assigns.current_subject

    account_policy =
      case Policies.fetch_policy(subject) do
        {:ok, policy} -> policy
        {:error, _} -> nil
      end

    socket
    |> assign(:loading?, false)
    |> assign(:can_manage?, Policies.subject_can_manage_policies?(subject))
    |> assign(:account, build_account_editor(account_policy))
    |> assign(:rulesets, Enum.map(list_scoped(subject), &build_ruleset_editor/1))
    |> assign(:runners, list_runners(subject))
    |> assign(:groups, list_groups(subject))
  end

  defp build_account_editor(policy) do
    rules = (policy && policy.rules) || Policies.default_rules()

    %{
      uid: "account",
      scope_type: :account,
      scope_value: "",
      defaults: normalize_defaults(rules["defaults"]),
      overrides: normalize_overrides(rules["overrides"]),
      approval: normalize_approval(rules),
      policy: policy,
      rules_errors: []
    }
  end

  defp build_ruleset_editor(%Policies.Policy{} = policy) do
    rules = policy.rules || Policies.default_rules()

    %{
      uid: policy.id,
      scope_type: policy.scope_type,
      scope_value: policy.scope_value,
      defaults: normalize_defaults(rules["defaults"]),
      overrides: normalize_overrides(rules["overrides"]),
      approval: normalize_approval(rules),
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

  defp list_scoped(subject) do
    case Policies.list_scoped_policies(subject) do
      {:ok, policies} -> policies
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
       %{editor | scope_type: scope_type, scope_value: scope_value}
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

  defp save_editor(socket, %{scope_type: scope, scope_value: value} = editor)
       when scope in [:runner, :group],
       do:
         persist(socket, editor, fn rules, subject ->
           Policies.save_scoped_rules(rules, scope, value, subject)
         end)

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
  defp replace_saved(socket, "account", policy),
    do: assign(socket, :account, build_account_editor(policy))

  defp replace_saved(socket, old_uid, policy) do
    rebuilt = build_ruleset_editor(policy)

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

  defp update_editor(socket, "account", fun),
    do: assign(socket, :account, fun.(socket.assigns.account))

  defp update_editor(socket, uid, fun) do
    rulesets =
      Enum.map(socket.assigns.rulesets, fn ruleset ->
        if ruleset.uid == uid, do: fun.(ruleset), else: ruleset
      end)

    assign(socket, :rulesets, rulesets)
  end

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
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:policies}
      width={:settings}
    >
      <:title>Policy</:title>

      <.loading_state :if={@loading?} />

      <div :if={not @loading?} class="space-y-6">
        <.page_intro>
          <:help>
            Every action has a <strong class="text-zinc-100">risk tier</strong>
            from the catalog. Your <strong class="text-zinc-100">default policy</strong>
            sets what happens per tier — allow, require approval, or deny — plus
            <strong class="text-zinc-100">overrides</strong>
            for the exceptions. Need different rules for one runner or a group? Add a
            <strong class="text-zinc-100">targeted ruleset</strong>
            below.
          </:help>
        </.page_intro>

        <p
          :if={not @can_manage?}
          class="rounded-lg border border-zinc-800 bg-zinc-900/40 px-4 py-2.5 text-xs text-zinc-400"
        >
          You can view the policy, but only owners and admins can change it.
        </p>

        <.panel title="Default policy">
          <:subtitle>Applies to every runner unless a targeted ruleset below overrides it.</:subtitle>

          <.policy_fields
            editor_id="account"
            defaults={@account.defaults}
            overrides={@account.overrides}
            approval={@account.approval}
            rules_errors={@account.rules_errors}
            can_manage={@can_manage?}
            save_label="Save default policy"
          />
        </.panel>

        <section class="space-y-4">
          <header class="flex items-end justify-between gap-4">
            <div>
              <h2 class="text-base font-semibold text-zinc-100">Targeted rulesets</h2>
              <p class="mt-0.5 max-w-xl text-xs text-zinc-500">
                A ruleset <strong class="text-zinc-300">replaces</strong>
                the default policy for one runner or group. Most specific wins — runner,
                then group, then the default policy.
              </p>
            </div>
            <.button
              :if={@can_manage?}
              variant="secondary"
              size="md"
              type="button"
              phx-click="add_ruleset"
              icon="hero-plus"
              disabled={not addable_any?(@runners, @groups, @rulesets)}
            >
              Add ruleset
            </.button>
          </header>

          <p
            :if={@rulesets == []}
            class="rounded-xl border border-dashed border-zinc-800 p-6 text-center text-xs text-zinc-500"
          >
            No targeted rulesets yet. Every runner uses the default policy above.
            <span :if={@can_manage?}>
              Add one to give a specific runner or group its own rules.
            </span>
          </p>

          <.ruleset_card
            :for={ruleset <- @rulesets}
            ruleset={ruleset}
            runners={@runners}
            groups={@groups}
            rulesets={@rulesets}
            can_manage={@can_manage?}
          />
        </section>
      </div>
    </.dashboard_shell>
    """
  end

  attr :ruleset, :map, required: true
  attr :runners, :list, required: true
  attr :groups, :list, required: true
  attr :rulesets, :list, required: true
  attr :can_manage, :boolean, required: true

  defp ruleset_card(assigns) do
    ~H"""
    <.card>
      <header class="flex items-start justify-between gap-4">
        <div class="min-w-0 flex-1">
          <%= if @ruleset.policy do %>
            <div class="flex items-center gap-2">
              <span class="rounded bg-zinc-800 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
                {@ruleset.scope_type}
              </span>
              <span class="truncate text-sm font-semibold text-zinc-100">
                {target_name(@ruleset, @runners)}
              </span>
            </div>
            <p class="mt-1 text-xs text-zinc-500">
              Replaces the default policy for this {@ruleset.scope_type}.
            </p>
          <% else %>
            <%!-- A form (not a lone select) so the uid rides along as a hidden
                 field on the change event, the same shape as the team page. --%>
            <form phx-change="set_target" class="sm:max-w-xs">
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
          <% end %>
        </div>

        <.button
          :if={@can_manage}
          variant="secondary"
          size="md"
          type="button"
          phx-click="remove_ruleset"
          phx-value-uid={@ruleset.uid}
          icon="hero-trash"
          data-confirm={
            @ruleset.policy &&
              "Remove this ruleset? That #{@ruleset.scope_type} falls back to the default policy."
          }
        >
          Remove
        </.button>
      </header>

      <.policy_fields
        :if={@ruleset.scope_type}
        editor_id={@ruleset.uid}
        defaults={@ruleset.defaults}
        overrides={@ruleset.overrides}
        approval={@ruleset.approval}
        rules_errors={@ruleset.rules_errors}
        can_manage={@can_manage}
        save_label="Save ruleset"
      />
      <p :if={is_nil(@ruleset.scope_type)} class="mt-4 text-xs text-zinc-500">
        Pick a runner or group above, then set its rules.
      </p>
    </.card>
    """
  end

  attr :editor_id, :string, required: true
  attr :defaults, :map, required: true
  attr :overrides, :list, required: true
  attr :approval, :map, required: true
  attr :rules_errors, :list, required: true
  attr :can_manage, :boolean, required: true
  attr :save_label, :string, required: true

  defp policy_fields(assigns) do
    ~H"""
    <form
      id={"policy-form-" <> @editor_id}
      phx-change="form_change"
      phx-submit="save"
      class="mt-4 space-y-5"
    >
      <input type="hidden" name="editor" value={@editor_id} />

      <%!-- The policy is structured data assembled server-side into one
           `rules` map, so a validation error keys to `:rules`, not a field.
           Render it inline (rose border) on this card — never a flash. The
           constrained selects + monotonic enforcement keep it empty in
           practice; this is the defensive net. --%>
      <.error_banner :for={msg <- @rules_errors}>{msg}</.error_banner>

      <div>
        <h3 class="text-sm font-semibold text-zinc-200">Risk-tier defaults</h3>
        <p class="mt-0.5 text-xs text-zinc-500">
          The default decision for any action in this tier. Overrides below win when they match.
        </p>
        <div class="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <.tier_card
            :for={tier <- ["low", "medium", "high", "critical"]}
            tier={tier}
            value={@defaults[tier]}
            floor_rank={tier_floor_rank(@defaults, tier)}
            can_manage={@can_manage}
          />
        </div>
        <p class="mt-2 text-xs text-zinc-500">
          Higher-risk tiers can't be more permissive than lower ones.
        </p>
      </div>

      <div>
        <div class="flex items-start justify-between gap-4">
          <div>
            <h3 class="text-sm font-semibold text-zinc-200">Per-action overrides</h3>
            <p class="mt-0.5 text-xs text-zinc-500">
              First match wins. Action supports wildcards (e.g. <code class="font-mono text-zinc-300">cassandra.*</code>).
            </p>
          </div>
          <.button
            :if={@can_manage}
            variant="secondary"
            size="md"
            type="button"
            phx-click="add_override"
            phx-value-editor={@editor_id}
            icon="hero-plus"
          >
            Add override
          </.button>
        </div>

        <div
          :if={@overrides == []}
          class="mt-4 rounded-lg border border-dashed border-zinc-800 p-6 text-center text-xs text-zinc-500"
        >
          No overrides. The tier defaults above decide every action.
        </div>

        <div :if={@overrides != []} class="mt-4 space-y-3">
          <%!-- First-match wins, so an override whose glob is subsumed by an
               earlier one is dead. Surface it inline (display-only, pure CPU on
               the in-memory rows) so an operator doesn't believe a deny they
               buried under a broader allow is in force. --%>
          <.override_card
            :for={{override, idx} <- Enum.with_index(@overrides)}
            editor_id={@editor_id}
            override={override}
            index={idx}
            shadowed_by={shadowed_by(@overrides, idx)}
            can_manage={@can_manage}
          />
        </div>
      </div>

      <%!-- Approval requirements: who, and how many, must approve a gated
           action. Defaults (1 distinct approver, self-approval allowed)
           reproduce single-approver behavior. --%>
      <div>
        <h3 class="text-sm font-semibold text-zinc-200">Approval requirements</h3>
        <p class="mt-0.5 text-xs text-zinc-500">
          Applies to any action this policy sends to the approval queue.
        </p>
        <div class="mt-3 grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div class="rounded-lg border border-zinc-800 bg-black/30 p-3">
            <.input
              type="number"
              name="policy[approval][min_approvals]"
              value={@approval["min_approvals"]}
              label="Required approvals"
              label_variant={:eyebrow}
              min="1"
              step="1"
              disabled={!@can_manage}
            />
            <p class="mt-1 text-[11px] leading-relaxed text-zinc-500">
              How many <em>distinct</em> operators must approve before the action runs.
            </p>
          </div>
          <div class="rounded-lg border border-zinc-800 bg-black/30 p-3">
            <.label variant={:eyebrow}>
              Self-approval
            </.label>
            <%!-- `unchecked_value` emits the companion hidden input so an
                 unchecked box still posts a value — a native checkbox posts
                 nothing when off. --%>
            <.checkbox
              class="mt-1 flex items-center gap-2 text-sm text-zinc-200"
              name="policy[approval][allow_self_approval]"
              value="true"
              unchecked_value="false"
              checked={@approval["allow_self_approval"]}
              disabled={!@can_manage}
              label="Let the requester approve their own action"
            />
            <p class="mt-1 text-[11px] leading-relaxed text-zinc-500">
              Off (GitHub-style) requires a <em>different</em> operator to approve.
            </p>
          </div>
        </div>
      </div>

      <div :if={@can_manage} class="flex justify-end border-t border-zinc-900 pt-4">
        <.button type="submit" phx-disable-with="Saving...">{@save_label}</.button>
      </div>
    </form>
    """
  end

  attr :tier, :string, required: true
  attr :value, :string, required: true
  attr :floor_rank, :integer, required: true
  attr :can_manage, :boolean, required: true

  defp tier_card(assigns) do
    ~H"""
    <label class={["block rounded-lg border bg-black/30 p-3", tier_border(@tier)]}>
      <div class="flex items-center justify-between">
        <span class="text-xs font-semibold uppercase tracking-wider text-zinc-200">{@tier}</span>
        <span class={["h-1.5 w-1.5 rounded-full", tier_dot(@tier)]}></span>
      </div>
      <%!-- Options below the floor are disabled — they'd make this tier
           more permissive than a lower-risk one, which the server rejects.
           Kept visible (not hidden) so the operator sees why. --%>
      <.select
        name={"policy[defaults][#{@tier}]"}
        disabled={!@can_manage}
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
    </label>
    """
  end

  attr :editor_id, :string, required: true
  attr :override, :map, required: true
  attr :index, :integer, required: true
  attr :shadowed_by, :integer, required: true
  attr :can_manage, :boolean, required: true

  defp override_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-800 bg-black/30 p-3">
      <div class="space-y-2 sm:grid sm:grid-cols-12 sm:items-end sm:gap-2 sm:space-y-0">
        <div class="sm:col-span-3">
          <.input
            name={"policy[overrides][#{@index}][name]"}
            value={@override["name"]}
            label="Name"
            label_variant={:eyebrow}
            placeholder="optional"
            disabled={!@can_manage}
          />
        </div>
        <div class="sm:col-span-5">
          <.input
            name={"policy[overrides][#{@index}][action]"}
            value={@override["action"]}
            label="Action (glob ok)"
            label_variant={:eyebrow}
            placeholder="e.g. cassandra.repair or linux.*"
            disabled={!@can_manage}
          />
        </div>
        <div class="sm:col-span-3">
          <.input
            name={"policy[overrides][#{@index}][decision]"}
            type="select"
            label="Decision"
            label_variant={:eyebrow}
            value={@override["decision"]}
            options={decision_options()}
            disabled={!@can_manage}
          />
        </div>
        <div class="sm:col-span-1 sm:flex sm:justify-end">
          <button
            :if={@can_manage}
            type="button"
            phx-click="remove_override"
            phx-value-editor={@editor_id}
            phx-value-index={@index}
            class="grid h-8 w-8 place-items-center rounded-lg border border-zinc-800 text-zinc-500 hover:border-rose-700 hover:text-rose-300"
            title="Remove override"
            aria-label="Remove override"
          >
            <.icon name="hero-trash" class="h-4 w-4" />
          </button>
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
    </div>
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

  defp tier_border("low"), do: "border-emerald-500/20"
  defp tier_border("medium"), do: "border-sky-500/20"
  defp tier_border("high"), do: "border-amber-500/20"
  defp tier_border("critical"), do: "border-rose-500/20"

  defp tier_dot("low"), do: "bg-emerald-400"
  defp tier_dot("medium"), do: "bg-sky-400"
  defp tier_dot("high"), do: "bg-amber-400"
  defp tier_dot("critical"), do: "bg-rose-400"
end
