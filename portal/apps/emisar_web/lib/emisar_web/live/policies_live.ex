defmodule EmisarWeb.PoliciesLive do
  use EmisarWeb, :live_view

  alias Emisar.Policies
  alias EmisarWeb.Permissions

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Policies")
     |> load()}
  end

  defp load(socket) do
    policies = Policies.list_policies(socket.assigns.current_account.id)
    assign(socket, :policies, policies)
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:policies}
    >
      <:title>Policies</:title>
      <:actions>
        <%= if Permissions.can?(assigns, :manage_policies) do %>
          <.link
            navigate={~p"/app/policies/new"}
            class="rounded-lg bg-indigo-500 px-3 py-1.5 text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
          >
            New policy
          </.link>
        <% end %>
      </:actions>

      <%= if @policies == [] do %>
        <.empty_state icon="hero-document-text" title="No policies yet">
          Policies decide whether an action call may proceed. Create one to gate runs with
          allow / deny / require-approval rules.
          <:cta :if={Permissions.can?(assigns, :manage_policies)} navigate={~p"/app/policies/new"}>
            Create policy
          </:cta>
        </.empty_state>
      <% else %>
        <.list_table id="policies" rows={@policies}>
          <:col :let={policy} label="Name">
            <.link
              navigate={~p"/app/policies/#{policy.id}/edit"}
              class="font-medium text-zinc-100 hover:text-indigo-300"
            >
              {policy.name}
            </.link>
            <%= if policy.is_default do %>
              <span class="ml-2 inline-flex items-center rounded-full bg-indigo-500/10 px-2 py-0.5 text-xs font-medium text-indigo-300 ring-1 ring-inset ring-indigo-500/30">
                default
              </span>
            <% end %>
            <div :if={policy.description} class="mt-0.5 text-xs text-zinc-500">
              {policy.description}
            </div>
          </:col>
          <:col :let={policy} label="Version">
            <span class="font-mono text-xs text-zinc-400">v{policy.version}</span>
          </:col>
          <:col :let={policy} label="Allow">
            <span class="text-xs text-zinc-400">{rule_count(policy, "allow")}</span>
          </:col>
          <:col :let={policy} label="Deny">
            <span class="text-xs text-zinc-400">{rule_count(policy, "deny")}</span>
          </:col>
          <:col :let={policy} label="Approval">
            <span class="text-xs text-zinc-400">{rule_count(policy, "require_approval")}</span>
          </:col>
          <:col :let={policy} label="Created">
            <span class="text-xs text-zinc-400">{relative_time(policy.inserted_at)}</span>
          </:col>
        </.list_table>
      <% end %>
    </.dashboard_shell>
    """
  end

  defp rule_count(%{rules: rules}, section) when is_map(rules) do
    case Map.get(rules, section) do
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end

  defp rule_count(_, _), do: 0
end
