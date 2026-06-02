defmodule EmisarWeb.PoliciesLive do
  @moduledoc """
  Two-section policy editor. Risk-tier defaults at the top (one
  decision per `low`/`medium`/`high`/`critical`), per-action overrides
  below. Operators rarely need overrides — the tier defaults cover the
  90% case in three clicks.
  """
  use EmisarWeb, :live_view

  alias Emisar.Policies
  alias EmisarWeb.Permissions

  @decisions Policies.decisions()
  @tiers Policies.risk_tiers()

  def mount(_params, _session, socket) do
    {:ok, load(socket) |> assign(:page_title, "Policy")}
  end

  defp load(socket) do
    policy =
      case Policies.fetch_policy(socket.assigns.current_subject) do
        {:ok, p} -> p
        {:error, _} -> nil
      end

    rules = (policy && policy.rules) || Policies.default_rules()

    socket
    |> assign(:policy, policy)
    |> assign(:defaults, normalize_defaults(rules["defaults"]))
    |> assign(:overrides, normalize_overrides(rules["overrides"]))
  end

  # -- Events ---------------------------------------------------------

  def handle_event("form_change", %{"policy" => params}, socket) do
    defaults =
      socket.assigns.defaults
      |> merge_defaults(params["defaults"] || %{})
      |> enforce_monotonic_defaults()

    overrides = merge_overrides(socket.assigns.overrides, params["overrides"] || [])
    {:noreply, socket |> assign(:defaults, defaults) |> assign(:overrides, overrides)}
  end

  def handle_event("form_change", _params, socket), do: {:noreply, socket}

  def handle_event("add_override", _params, socket) do
    overrides = socket.assigns.overrides ++ [empty_override()]
    {:noreply, assign(socket, :overrides, overrides)}
  end

  def handle_event("remove_override", %{"index" => idx}, socket) do
    i = String.to_integer(idx)
    overrides = List.delete_at(socket.assigns.overrides, i)
    {:noreply, assign(socket, :overrides, overrides)}
  end

  def handle_event("save", _params, socket) do
    Permissions.gated(socket, :manage_policies, fn s ->
      rules = to_rules(s.assigns.defaults, s.assigns.overrides)

      case Policies.save_rules(rules, s.assigns.current_subject) do
        {:ok, _policy} ->
          {:noreply, s |> put_flash(:info, "Policy saved.") |> load()}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply, put_flash(s, :error, "Could not save policy: #{format_errors(cs)}")}
      end
    end)
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
    Enum.map(list, fn ov ->
      %{
        "name" => ov["name"] || "",
        "action" => ov["action"] || "",
        "decision" => if(ov["decision"] in @decisions, do: ov["decision"], else: "allow")
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
    |> Enum.map(fn {ov, i} ->
      case Enum.at(form_list, i) do
        nil -> ov
        form_ov -> Map.merge(ov, Map.take(form_ov, ["name", "action", "decision"]))
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
        |> Enum.map(fn ov ->
          %{
            "name" => String.trim(ov["name"] || ""),
            "action" => String.trim(ov["action"]),
            "decision" => ov["decision"]
          }
        end)
    }
  end

  defp blank_action?(ov), do: blank?(ov["action"])

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp format_errors(%Ecto.Changeset{errors: errors}) do
    errors |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end) |> Enum.join("; ")
  end

  # -- Render ---------------------------------------------------------

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      pending_approvals_count={@pending_approvals_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:policies}
    >
      <:title>Policy</:title>
      <:actions :if={Permissions.can?(assigns, :manage_policies)}>
        <.button type="submit" form="policy-form" phx-disable-with="Saving...">Save</.button>
      </:actions>

      <div class="mx-auto max-w-4xl space-y-6">
        <section class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-5">
          <h2 class="text-sm font-semibold text-zinc-100">How this works</h2>
          <p class="mt-2 text-sm leading-relaxed text-zinc-400">
            Every action belongs to a <strong class="text-zinc-100">risk tier</strong>
            (declared in the catalog). Pick what should happen by tier — that's the policy.
            Use <strong class="text-zinc-100">overrides</strong>
            to single out specific actions that don't fit their tier.
          </p>
        </section>

        <form id="policy-form" phx-change="form_change" phx-submit="save" class="space-y-6">
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
                  can_manage={Permissions.can?(assigns, :manage_policies)}
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
                :if={Permissions.can?(assigns, :manage_policies)}
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
              <%= for {ov, idx} <- Enum.with_index(@overrides) do %>
                <.override_card
                  override={ov}
                  index={idx}
                  can_manage={Permissions.can?(assigns, :manage_policies)}
                />
              <% end %>
            </div>
          </section>
        </form>
      </div>
    </.dashboard_shell>
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
