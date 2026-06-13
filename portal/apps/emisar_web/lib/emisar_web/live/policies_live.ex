defmodule EmisarWeb.PoliciesLive do
  @moduledoc """
  Policy editor with a scope switcher. The same two-section editor
  (risk-tier defaults + per-action overrides) edits one policy at a
  time: the account default, or a per-runner / per-group override.

  A runner or group override **replaces** the account policy for that
  scope — most specific wins (runner > group > account), it doesn't
  layer on top. New overrides start from the account default's rules as
  a convenient baseline, then the operator tweaks from there.
  """
  use EmisarWeb, :live_view

  alias Emisar.Policies
  alias Emisar.Runners
  alias EmisarWeb.Permissions

  @decisions Policies.decisions()
  @tiers Policies.risk_tiers()

  def mount(_params, _session, socket) do
    socket = assign(socket, page_title: "Policy", loading?: not connected?(socket))
    {:ok, if(connected?(socket), do: load_scope(socket, :account, ""), else: socket)}
  end

  # Load everything the page needs for the active scope: the scope's
  # policy (or a fresh form seeded from the account default for a not-yet-
  # saved override), plus the runner/group pickers and the list of existing
  # overrides that drive the switcher.
  defp load_scope(socket, scope_type, scope_value) do
    subject = socket.assigns.current_subject

    account_policy =
      case Policies.fetch_policy(subject) do
        {:ok, policy} -> policy
        {:error, _} -> nil
      end

    account_rules = (account_policy && account_policy.rules) || Policies.default_rules()

    {policy, rules} =
      active_policy(scope_type, scope_value, account_policy, account_rules, subject)

    defaults = normalize_defaults(rules["defaults"])
    overrides = normalize_overrides(rules["overrides"])

    socket
    |> assign(:loading?, false)
    |> assign(:scope_type, scope_type)
    |> assign(:scope_value, scope_value)
    |> assign(:policy, policy)
    |> assign(:runners, list_runners(subject))
    |> assign(:groups, list_groups(subject))
    |> assign(:scoped_policies, list_scoped(subject))
    |> assign(:defaults, defaults)
    |> assign(:overrides, overrides)
    |> assign_form(Policies.change_policy(to_rules(defaults, overrides)))
  end

  defp active_policy(:account, _value, account_policy, account_rules, _subject),
    do: {account_policy, account_rules}

  defp active_policy(scope, value, _account_policy, account_rules, subject) do
    case Policies.fetch_scoped_policy(scope, value, subject) do
      {:ok, policy} -> {policy, policy.rules}
      # No row yet — a new override, seeded from the account baseline.
      {:error, _} -> {nil, account_rules}
    end
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

  def handle_event("switch_scope", %{"scope" => "account"}, socket),
    do: {:noreply, load_scope(socket, :account, "")}

  def handle_event("switch_scope", %{"scope" => "runner", "value" => value}, socket),
    do: {:noreply, load_scope(socket, :runner, value)}

  def handle_event("switch_scope", %{"scope" => "group", "value" => value}, socket),
    do: {:noreply, load_scope(socket, :group, value)}

  def handle_event("add_runner_scope", %{"runner_id" => ""}, socket), do: {:noreply, socket}

  def handle_event("add_runner_scope", %{"runner_id" => id}, socket),
    do: {:noreply, load_scope(socket, :runner, id)}

  def handle_event("add_group_scope", %{"group" => ""}, socket), do: {:noreply, socket}

  def handle_event("add_group_scope", %{"group" => group}, socket),
    do: {:noreply, load_scope(socket, :group, group)}

  def handle_event("form_change", %{"policy" => params}, socket) do
    defaults =
      socket.assigns.defaults
      |> merge_defaults(params["defaults"] || %{})
      |> enforce_monotonic_defaults()

    overrides = merge_overrides(socket.assigns.overrides, params["overrides"] || [])
    changeset = Map.put(Policies.change_policy(to_rules(defaults, overrides)), :action, :validate)

    {:noreply,
     socket
     |> assign(:defaults, defaults)
     |> assign(:overrides, overrides)
     |> assign_form(changeset)}
  end

  def handle_event("form_change", _params, socket), do: {:noreply, socket}

  def handle_event("add_override", _params, socket) do
    overrides = socket.assigns.overrides ++ [empty_override()]
    {:noreply, assign(socket, :overrides, overrides)}
  end

  def handle_event("remove_override", %{"index" => idx}, socket) do
    case Integer.parse(idx) do
      {i, _} ->
        overrides = List.delete_at(socket.assigns.overrides, i)
        {:noreply, assign(socket, :overrides, overrides)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("save", _params, socket) do
    Permissions.gated(
      socket,
      Policies.subject_can_manage_policies?(socket.assigns.current_subject),
      fn socket ->
        rules = to_rules(socket.assigns.defaults, socket.assigns.overrides)

        case save_active(socket, rules) do
          {:ok, _policy} ->
            {:noreply,
             socket
             |> put_flash(:info, "Policy saved.")
             |> load_scope(socket.assigns.scope_type, socket.assigns.scope_value)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
        end
      end
    )
  end

  def handle_event("delete_scope", _params, socket) do
    Permissions.gated(
      socket,
      Policies.subject_can_manage_policies?(socket.assigns.current_subject),
      fn socket ->
        case socket.assigns.policy do
          %Policies.Policy{scope_type: scope} = policy when scope in [:runner, :group] ->
            delete_and_reload(socket, policy)

          # Account scope or a not-yet-saved override — nothing to delete.
          _ ->
            {:noreply, socket}
        end
      end
    )
  end

  defp save_active(socket, rules) do
    subject = socket.assigns.current_subject

    case socket.assigns.scope_type do
      :account -> Policies.save_rules(rules, subject)
      scope -> Policies.save_scoped_rules(rules, scope, socket.assigns.scope_value, subject)
    end
  end

  defp delete_and_reload(socket, policy) do
    case Policies.delete_scoped_policy(policy, socket.assigns.current_subject) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, "Override removed — that scope falls back to the account default.")
         |> load_scope(:account, "")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not remove override.")}
    end
  end

  # -- State helpers --------------------------------------------------

  defp normalize_defaults(nil), do: default_defaults()

  defp normalize_defaults(%{} = d) do
    Enum.into(@tiers, %{}, fn tier ->
      val = d[tier]
      {tier, if(val in @decisions, do: val, else: default_decision(tier))}
    end)
  end

  defp default_defaults do
    Enum.into(@tiers, %{}, fn t -> {t, default_decision(t)} end)
  end

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

  defp merge_defaults(state, form) when is_map(form) do
    Enum.into(@tiers, state, fn tier ->
      val = form[tier] || state[tier]
      {tier, if(val in @decisions, do: val, else: state[tier])}
    end)
  end

  # Walk left-to-right, lifting any tier that's more permissive than
  # its predecessor up to the predecessor's level. Means a change to
  # `low=deny` instantly bumps medium/high/critical to deny too — the
  # operator never sees a transient invalid state on the page.
  defp enforce_monotonic_defaults(defaults) do
    @tiers
    |> Enum.reduce({defaults, 0}, fn tier, {acc, floor_rank} ->
      val = acc[tier]
      cur_rank = Policies.decision_rank(val)

      {new_val, new_rank} =
        if cur_rank < floor_rank do
          {decision_at_rank(floor_rank), floor_rank}
        else
          {val, cur_rank}
        end

      {Map.put(acc, tier, new_val), new_rank}
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
        nil -> override
        form_ov -> Map.merge(override, Map.take(form_ov, ["name", "action", "decision"]))
      end
    end)
  end

  defp normalize_indexed(list) when is_list(list), do: list

  defp normalize_indexed(%{} = m) do
    m
    |> Enum.sort_by(fn {k, _} ->
      case Integer.parse(to_string(k)) do
        {n, _} -> n
        :error -> 0
      end
    end)
    |> Enum.map(fn {_, v} -> v end)
  end

  defp normalize_indexed(_), do: []

  defp to_rules(defaults, overrides) do
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
        end)
    }
  end

  defp blank_action?(override), do: blank?(override["action"])

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "policy"))
  end

  # -- Scope helpers --------------------------------------------------

  defp scope_label(:runner, value, runners), do: runner_name(runners, value)
  defp scope_label(:group, value, _runners), do: value

  # Resolve a runner id to its name for display; fall back to the id when
  # the runner has since been deleted so the override stays identifiable.
  defp runner_name(runners, id) do
    case Enum.find(runners, &(&1.id == id)) do
      %{name: name} -> name
      nil -> id
    end
  end

  defp active_scope_title(%{scope_type: :account}), do: "Account default"

  defp active_scope_title(%{scope_type: :runner, scope_value: value, runners: runners}),
    do: "Runner override · " <> runner_name(runners, value)

  defp active_scope_title(%{scope_type: :group, scope_value: value}),
    do: "Group override · " <> value

  defp scope_active?(assigns, scope_type, scope_value),
    do: assigns.scope_type == scope_type and assigns.scope_value == scope_value

  # Runners / groups that don't yet have an override — the "add" pickers
  # only offer new scopes; existing ones are reached through the pills.
  defp addable_runners(runners, scoped_policies) do
    taken = scope_values(scoped_policies, :runner)
    Enum.reject(runners, &MapSet.member?(taken, &1.id))
  end

  defp addable_groups(groups, scoped_policies) do
    taken = scope_values(scoped_policies, :group)
    Enum.reject(groups, &MapSet.member?(taken, &1))
  end

  defp scope_values(scoped_policies, scope_type) do
    for %{scope_type: ^scope_type, scope_value: value} <- scoped_policies,
        into: MapSet.new(),
        do: value
  end

  defp deletable_scope?(%{scope_type: scope, policy: policy}),
    do: scope in [:runner, :group] and not is_nil(policy)

  defp unsaved_scope?(%{scope_type: scope, policy: policy}),
    do: scope in [:runner, :group] and is_nil(policy)

  # -- Render ---------------------------------------------------------

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:policies}
    >
      <:title>Policy</:title>
      <:actions :if={not @loading? and Policies.subject_can_manage_policies?(@current_subject)}>
        <.button type="submit" form="policy-form" phx-disable-with="Saving...">Save</.button>
      </:actions>

      <.loading_state :if={@loading?} />

      <div :if={not @loading?} class="mx-auto max-w-4xl space-y-6">
        <section class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-5">
          <h2 class="text-sm font-semibold text-zinc-100">How this works</h2>
          <p class="mt-2 text-sm leading-relaxed text-zinc-400">
            Every action belongs to a <strong class="text-zinc-100">risk tier</strong>
            (declared in the catalog). Pick what should happen by tier — that's the policy.
            Use <strong class="text-zinc-100">overrides</strong>
            to single out specific actions that don't fit their tier.
          </p>
        </section>

        <section class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-5">
          <header>
            <h2 class="text-base font-semibold text-zinc-100">Scope</h2>
            <p class="mt-0.5 text-xs text-zinc-500">
              The account policy applies fleet-wide. A runner or group override
              <strong class="text-zinc-300">replaces</strong>
              it for that runner or group — most specific wins (runner &gt; group &gt; account),
              it doesn't layer on top.
            </p>
          </header>

          <div class="mt-4 flex flex-wrap gap-2">
            <.scope_pill
              label="Account default"
              scope="account"
              value=""
              active={@scope_type == :account}
            />
            <.scope_pill
              :for={policy <- @scoped_policies}
              label={scope_label(policy.scope_type, policy.scope_value, @runners)}
              kind={policy.scope_type}
              scope={to_string(policy.scope_type)}
              value={policy.scope_value}
              active={scope_active?(assigns, policy.scope_type, policy.scope_value)}
            />
          </div>

          <div
            :if={Policies.subject_can_manage_policies?(@current_subject)}
            class="mt-4 grid gap-3 sm:grid-cols-2"
          >
            <div :if={addable_runners(@runners, @scoped_policies) != []}>
              <label class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
                Add a runner override
              </label>
              <select name="runner_id" phx-change="add_runner_scope" class={input_class()}>
                <option value="">Pick a runner…</option>
                <option :for={runner <- addable_runners(@runners, @scoped_policies)} value={runner.id}>
                  {runner.name}
                </option>
              </select>
            </div>

            <div :if={addable_groups(@groups, @scoped_policies) != []}>
              <label class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
                Add a group override
              </label>
              <select name="group" phx-change="add_group_scope" class={input_class()}>
                <option value="">Pick a group…</option>
                <option :for={group <- addable_groups(@groups, @scoped_policies)} value={group}>
                  {group}
                </option>
              </select>
            </div>
          </div>
        </section>

        <div class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-zinc-900 bg-zinc-950/40 px-5 py-3">
          <div class="flex items-center gap-2 text-sm">
            <span class="text-zinc-500">Editing</span>
            <span class="font-medium text-zinc-100">{active_scope_title(assigns)}</span>
            <span
              :if={unsaved_scope?(assigns)}
              class="rounded bg-amber-500/10 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-amber-300"
            >
              new
            </span>
          </div>
          <button
            :if={
              deletable_scope?(assigns) and Policies.subject_can_manage_policies?(@current_subject)
            }
            type="button"
            phx-click="delete_scope"
            data-confirm="Remove this override? That runner/group falls back to the account default."
            class="inline-flex items-center gap-1.5 rounded-lg border border-zinc-800 px-3 py-1.5 text-xs font-medium text-zinc-400 hover:border-rose-700 hover:text-rose-300"
          >
            <.icon name="hero-trash" class="h-3.5 w-3.5" /> Remove override
          </button>
        </div>

        <form id="policy-form" phx-change="form_change" phx-submit="save" class="space-y-6">
          <%!-- The policy is structured data (tier defaults + overrides) assembled
               server-side into a single `rules` map, so every changeset error keys
               to `:rules` rather than a single input. Render it inline at the top of
               the form — rose-bordered, under the fields it concerns — not a flash. --%>
          <div
            :for={{msg, _opts} <- @form[:rules].errors}
            class="rounded-lg border border-rose-500/40 bg-rose-500/5 px-4 py-3"
          >
            <p class="flex items-start gap-1.5 text-sm text-rose-400">
              <.icon name="hero-exclamation-circle-mini" class="mt-0.5 h-4 w-4 flex-none" />
              <span>{msg}</span>
            </p>
          </div>

          <section class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-5">
            <header>
              <h2 class="text-base font-semibold text-zinc-100">Risk-tier defaults</h2>
              <p class="mt-0.5 text-xs text-zinc-500">
                The default decision for any action in this tier. Overrides below win when they match.
              </p>
            </header>

            <div class="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <%= for tier <- ["low", "medium", "high", "critical"] do %>
                <.tier_card
                  tier={tier}
                  value={@defaults[tier]}
                  floor_rank={tier_floor_rank(@defaults, tier)}
                  can_manage={Policies.subject_can_manage_policies?(@current_subject)}
                />
              <% end %>
            </div>

            <p class="mt-3 text-xs leading-relaxed text-zinc-500">
              Higher-risk tiers can't be more permissive than lower ones.
              Setting <strong class="text-zinc-300">low</strong>
              to <em>Deny</em>
              forces the rest to <em>Deny</em>
              too — there's no scenario where blocking a safe action while letting a critical one through makes sense.
            </p>
          </section>

          <section class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-5">
            <header class="flex items-start justify-between gap-4">
              <div>
                <h2 class="text-base font-semibold text-zinc-100">Per-action overrides</h2>
                <p class="mt-0.5 text-xs text-zinc-500">
                  First match wins. Action supports wildcards (e.g. <code class="font-mono text-zinc-300">cassandra.*</code>).
                </p>
              </div>
              <button
                :if={Policies.subject_can_manage_policies?(@current_subject)}
                type="button"
                phx-click="add_override"
                class="inline-flex shrink-0 items-center gap-1.5 rounded-lg border border-zinc-800 px-3 py-1.5 text-xs font-medium text-zinc-300 hover:border-indigo-500 hover:text-indigo-300"
              >
                <.icon name="hero-plus" class="h-3.5 w-3.5" /> Add override
              </button>
            </header>

            <div
              :if={@overrides == []}
              class="mt-5 rounded-lg border border-dashed border-zinc-800 p-6 text-center text-xs text-zinc-500"
            >
              No overrides. The tier defaults above decide every action.
            </div>

            <div :if={@overrides != []} class="mt-5 space-y-3">
              <%= for {override, idx} <- Enum.with_index(@overrides) do %>
                <.override_card
                  override={override}
                  index={idx}
                  can_manage={Policies.subject_can_manage_policies?(@current_subject)}
                />
              <% end %>
            </div>
          </section>
        </form>
      </div>
    </.dashboard_shell>
    """
  end

  attr :label, :string, required: true
  attr :scope, :string, required: true
  attr :value, :string, required: true
  attr :active, :boolean, required: true
  attr :kind, :atom, default: :account

  defp scope_pill(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="switch_scope"
      phx-value-scope={@scope}
      phx-value-value={@value}
      class={[
        "inline-flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-xs font-medium",
        @active && "border-indigo-500 bg-indigo-500/10 text-indigo-200",
        !@active && "border-zinc-800 text-zinc-400 hover:border-zinc-600 hover:text-zinc-200"
      ]}
    >
      <span
        :if={@kind != :account}
        class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500"
      >
        {@kind}
      </span>
      {@label}
    </button>
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
      <select
        name={"policy[defaults][#{@tier}]"}
        class="mt-2 block w-full rounded-lg border-0 bg-zinc-900 px-2 py-1.5 text-sm text-zinc-100 ring-1 ring-zinc-800 focus:ring-indigo-500 disabled:opacity-50"
        disabled={!@can_manage}
      >
        <%!-- Options ranked below the floor are disabled — they'd
             make this tier more permissive than a lower-risk tier,
             which the server rejects too. Disabled options stay
             visible so the operator understands why they can't pick
             them, instead of silently hiding the choices. --%>
        <%= for {label, val} <- decision_options() do %>
          <option
            value={val}
            selected={@value == val}
            disabled={Policies.decision_rank(val) < @floor_rank}
          >
            {label}
          </option>
        <% end %>
      </select>
    </label>
    """
  end

  defp decision_options do
    [{"Allow", "allow"}, {"Require approval", "require_approval"}, {"Deny", "deny"}]
  end

  # The rank below which a tier's decision can't drop. For `low` it's 0
  # (anything goes); for any other tier it's the rank of the
  # immediately-lower tier. Walking left-to-right because the LV's
  # state has already been monotonized in `enforce_monotonic_defaults`,
  # so we can read the lower tier's value directly.
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

  attr :override, :map, required: true
  attr :index, :integer, required: true
  attr :can_manage, :boolean, required: true

  defp override_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-800 bg-black/30 p-3">
      <div class="space-y-2 sm:grid sm:grid-cols-12 sm:items-end sm:gap-2 sm:space-y-0">
        <div class="sm:col-span-3">
          <label class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
            Name
          </label>
          <input
            type="text"
            name={"policy[overrides][#{@index}][name]"}
            value={@override["name"]}
            placeholder="optional"
            class={input_class()}
            disabled={!@can_manage}
          />
        </div>
        <div class="sm:col-span-5">
          <label class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
            Action (glob ok)
          </label>
          <input
            type="text"
            name={"policy[overrides][#{@index}][action]"}
            value={@override["action"]}
            placeholder="e.g. cassandra.repair or linux.*"
            class={input_class()}
            disabled={!@can_manage}
          />
        </div>
        <div class="sm:col-span-3">
          <label class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
            Decision
          </label>
          <select
            name={"policy[overrides][#{@index}][decision]"}
            class={input_class()}
            disabled={!@can_manage}
          >
            <%= for {label, val} <- decision_options() do %>
              <option value={val} selected={@override["decision"] == val}>{label}</option>
            <% end %>
          </select>
        </div>
        <div class="sm:col-span-1 sm:flex sm:justify-end">
          <button
            :if={@can_manage}
            type="button"
            phx-click="remove_override"
            phx-value-index={@index}
            class="grid h-8 w-8 place-items-center rounded-lg border border-zinc-800 text-zinc-500 hover:border-rose-700 hover:text-rose-300"
            title="Remove override"
            aria-label="Remove override"
          >
            <.icon name="hero-trash" class="h-4 w-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp input_class do
    "mt-1 block w-full rounded-lg border-0 bg-zinc-900 px-2 py-1.5 text-sm text-zinc-100 ring-1 ring-zinc-800 focus:ring-indigo-500 disabled:opacity-50"
  end
end
