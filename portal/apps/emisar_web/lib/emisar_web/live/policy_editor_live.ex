defmodule EmisarWeb.PolicyEditorLive do
  use EmisarWeb, :live_view

  alias Emisar.Policies
  alias Emisar.Policies.Policy
  alias EmisarWeb.Permissions

  @default_rules %{"allow" => [], "deny" => [], "require_approval" => []}

  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New policy")
    |> assign(:policy, nil)
    |> assign(:name, "")
    |> assign(:description, "")
    |> assign(:is_default, false)
    |> assign(:rules_json, Jason.encode!(@default_rules, pretty: true))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    account_id = socket.assigns.current_account.id

    case Policies.get_policy(account_id, id) do
      nil ->
        socket
        |> put_flash(:error, "Policy not found.")
        |> push_navigate(to: ~p"/app/policies")

      policy ->
        socket
        |> assign(:page_title, "Edit policy")
        |> assign(:policy, policy)
        |> assign(:name, policy.name)
        |> assign(:description, policy.description || "")
        |> assign(:is_default, policy.is_default)
        |> assign(:rules_json, Jason.encode!(policy.rules || @default_rules, pretty: true))
    end
  end

  def handle_event("validate", params, socket) do
    {:noreply,
     socket
     |> assign(:name, params["name"] || "")
     |> assign(:description, params["description"] || "")
     |> assign(:is_default, params["is_default"] == "true")
     |> assign(:rules_json, params["rules_json"] || socket.assigns.rules_json)}
  end

  def handle_event("save", params, socket) do
    Permissions.gated(socket, :manage_policies, fn s -> do_save(s, params) end)
  end

  defp do_save(socket, params) do
    name = params["name"] || ""
    description = params["description"] || ""
    is_default = params["is_default"] == "true"
    rules_json = params["rules_json"] || "{}"

    socket =
      socket
      |> assign(:name, name)
      |> assign(:description, description)
      |> assign(:is_default, is_default)
      |> assign(:rules_json, rules_json)

    with {:ok, rules} <- decode_rules(rules_json),
         attrs <- %{
           "name" => name,
           "description" => description,
           "is_default" => is_default,
           "rules" => rules
         },
         {:ok, _policy} <- persist(socket, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, success_message(socket))
       |> push_navigate(to: ~p"/app/policies")}
    else
      {:error, :invalid_json, msg} ->
        {:noreply, put_flash(socket, :error, "Invalid JSON in rules: #{msg}")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, "Could not save policy: #{format_errors(cs)}")}
    end
  end

  defp persist(%{assigns: %{policy: nil}} = socket, attrs) do
    Policies.create_policy(socket.assigns.current_account.id, attrs, socket.assigns.current_user.id)
  end

  defp persist(%{assigns: %{policy: %Policy{} = policy}} = socket, attrs) do
    Policies.save_new_version(policy, attrs, socket.assigns.current_user.id)
  end

  defp success_message(%{assigns: %{policy: nil}}), do: "Policy created."
  defp success_message(_), do: "New policy version saved."

  defp decode_rules(json) do
    case Jason.decode(json) do
      {:ok, %{} = rules} -> {:ok, rules}
      {:ok, _} -> {:error, :invalid_json, "must be a JSON object"}
      {:error, %Jason.DecodeError{} = err} -> {:error, :invalid_json, Exception.message(err)}
    end
  end

  defp format_errors(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
    |> Enum.join("; ")
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:policies}
    >
      <:title>
        <%= if @policy do %>
          Edit policy <span class="font-mono text-base text-zinc-400">{@policy.name}</span>
          <span class="ml-2 text-sm font-normal text-zinc-500">v{@policy.version}</span>
        <% else %>
          New policy
        <% end %>
      </:title>
      <:actions>
        <.link
          navigate={~p"/app/policies"}
          class="rounded-lg border border-zinc-800 px-3 py-1.5 text-sm font-medium text-zinc-300 hover:bg-zinc-900"
        >
          Cancel
        </.link>
      </:actions>

      <form phx-change="validate" phx-submit="save" class="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <.card class="lg:col-span-2">
          <.section_header title="Rules" />
          <p class="mt-1 text-xs text-zinc-500">
            JSON object with <code class="text-indigo-300">allow</code>,
            <code class="text-indigo-300">deny</code>,
            and <code class="text-indigo-300">require_approval</code>
            arrays. Each rule may include <code>name</code>, <code>action</code> (glob),
            <code>max_risk</code>, <code>kind</code>, and <code>args</code> conditions.
          </p>

          <textarea
            name="rules_json"
            rows="22"
            spellcheck="false"
            class="mt-4 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2 font-mono text-xs text-zinc-100 ring-1 ring-zinc-800 focus:ring-indigo-500"
          ><%= @rules_json %></textarea>

          <div class="mt-6 flex items-center justify-end gap-3">
            <.button type="submit" phx-disable-with="Saving...">
              <%= if @policy, do: "Save new version", else: "Create policy" %>
            </.button>
          </div>
        </.card>

        <div class="space-y-6">
          <.card>
            <.section_header title="Settings" />

            <div class="mt-4 space-y-4">
              <div>
                <label class="block text-xs font-medium text-zinc-400" for="policy_name">
                  Name
                </label>
                <input
                  type="text"
                  id="policy_name"
                  name="name"
                  value={@name}
                  required
                  placeholder="e.g. production-default"
                  class="mt-1 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2 text-sm text-zinc-100 ring-1 ring-zinc-800 focus:ring-indigo-500"
                />
              </div>

              <div>
                <label class="block text-xs font-medium text-zinc-400" for="policy_description">
                  Description
                </label>
                <textarea
                  id="policy_description"
                  name="description"
                  rows="3"
                  placeholder="Optional human-readable summary."
                  class="mt-1 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2 text-sm text-zinc-100 ring-1 ring-zinc-800 focus:ring-indigo-500"
                ><%= @description %></textarea>
              </div>

              <label class="flex items-center gap-2 text-sm text-zinc-300">
                <input type="hidden" name="is_default" value="false" />
                <input
                  type="checkbox"
                  name="is_default"
                  value="true"
                  checked={@is_default}
                  class="rounded border-zinc-700 bg-zinc-900 text-indigo-500 focus:ring-indigo-500"
                />
                Make this the default policy
              </label>
            </div>
          </.card>

          <%= if @policy do %>
            <.card>
              <dl class="space-y-2 text-xs text-zinc-400">
                <.kv label="Current version">v{@policy.version}</.kv>
                <.kv label="Saving creates">v{@policy.version + 1}</.kv>
              </dl>
            </.card>
          <% end %>
        </div>
      </form>
    </.dashboard_shell>
    """
  end
end
