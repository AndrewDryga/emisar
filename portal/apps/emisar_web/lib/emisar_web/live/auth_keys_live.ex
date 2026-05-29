defmodule EmisarWeb.AuthKeysLive do
  use EmisarWeb, :live_view

  alias Emisar.Runners
  alias EmisarWeb.Permissions

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Auth keys")
     |> assign(:new_secret, nil)
     |> assign(:new_key, nil)
     |> assign_form(default_params())
     |> load()}
  end

  def handle_event("validate", %{"auth_key" => params}, socket) do
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("create", %{"auth_key" => params}, socket) do
    Permissions.gated(socket, :manage_auth_keys, &do_create(&1, params))
  end

  def handle_event("dismiss_secret", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_secret, nil)
     |> assign(:new_key, nil)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    Permissions.gated(socket, :manage_auth_keys, fn s -> do_revoke(s, id) end)
  end

  defp do_create(socket, params) do
    account_id = socket.assigns.current_account.id
    user_id = socket.assigns.current_user.id

    attrs =
      %{}
      |> put_if_present(:description, params["description"])
      |> put_if_present(:group, params["group"])
      |> Map.put(:reusable, truthy?(params["reusable"]))
      |> put_expires(params["expires_at"])

    case Runners.create_auth_key(account_id, user_id, attrs) do
      {:ok, raw, key} ->
        {:noreply,
         socket
         |> put_flash(:info, "Auth key created. Copy it now — you won't see it again.")
         |> assign(:new_secret, raw)
         |> assign(:new_key, key)
         |> assign_form(default_params())
         |> load()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not create key: #{inspect(changeset.errors)}")}
    end
  end

  defp do_revoke(socket, id) do
    account_id = socket.assigns.current_account.id
    user_id = socket.assigns.current_user.id

    case Enum.find(socket.assigns.auth_keys, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      key ->
        if key.account_id == account_id do
          {:ok, _} = Runners.revoke_auth_key(key, user_id)
          {:noreply, socket |> put_flash(:info, "Key revoked.") |> load()}
        else
          {:noreply, socket}
        end
    end
  end

  defp load(socket) do
    assign(socket, :auth_keys, Runners.list_auth_keys(socket.assigns.current_account.id))
  end

  defp default_params do
    %{"description" => "", "group" => "default", "reusable" => "false", "expires_at" => ""}
  end

  defp assign_form(socket, params) do
    assign(socket, :form, to_form(params, as: "auth_key"))
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp put_expires(map, value) when value in [nil, ""], do: map

  defp put_expires(map, value) when is_binary(value) do
    case DateTime.from_iso8601(value <> ":00Z") do
      {:ok, dt, _} -> Map.put(map, :expires_at, DateTime.truncate(dt, :microsecond))
      _ -> map
    end
  end

  defp truthy?("true"), do: true
  defp truthy?(true), do: true
  defp truthy?("on"), do: true
  defp truthy?(_), do: false

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:auth_keys}
    >
      <:title>Runner auth keys</:title>

      <%= if @new_secret do %>
        <.secret_reveal
          title="Copy this auth key now — it will not be shown again."
          secret={@new_secret}
          on_dismiss="dismiss_secret"
        >
          Treat it like a password. Anyone with this key can register a runner
          under <span class="font-semibold">{@current_account.name}</span>.

          <:install_command>
            curl -sSL https://emisar.com/install.sh | sudo EMISAR_AUTH_KEY={@new_secret} bash
          </:install_command>
        </.secret_reveal>
      <% end %>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <%= if Permissions.can?(assigns, :manage_auth_keys) do %>
          <.card class="lg:col-span-1">
            <.section_header title="Issue a new key" />
            <p class="mt-1 text-xs text-zinc-500">
              Reusable keys are best for stable fleets; single-use keys are right for autoscalers.
            </p>

            <.simple_form for={@form} id="auth_key_form" phx-change="validate" phx-submit="create">
              <.input
                field={@form[:description]}
                type="text"
                label="Description"
                placeholder="prod web tier"
              />
              <.input
                field={@form[:group]}
                type="text"
                label="Group"
                placeholder="default"
              />
              <.input
                field={@form[:reusable]}
                type="checkbox"
                label="Reusable (allows many runners to register with this key)"
              />
              <.input
                field={@form[:expires_at]}
                type="datetime-local"
                label="Expires at (optional)"
              />

              <:actions>
                <.button phx-disable-with="Creating..." class="w-full">
                  Create auth key
                </.button>
              </:actions>
            </.simple_form>
          </.card>
        <% else %>
          <.card class="lg:col-span-1">
            <.section_header title="Issue a new key" />
            <p class="mt-4 rounded-lg bg-zinc-900/60 p-4 text-xs text-zinc-400">
              Only owners and admins can issue auth keys.
            </p>
          </.card>
        <% end %>

        <.card class="lg:col-span-2">
          <.section_header title="Current keys" />

          <%= if @auth_keys == [] do %>
            <div class="mt-4">
              <.empty_state icon="hero-key" title="No auth keys yet">
                No auth keys yet. Issue one to bootstrap a runner.
              </.empty_state>
            </div>
          <% else %>
            <div class="mt-4">
              <.list_table id="auth-keys" rows={@auth_keys}>
                <:col :let={key} label="Prefix">
                  <span class="font-mono text-xs text-zinc-200">{key.key_prefix}…</span>
                </:col>
                <:col :let={key} label="Description">
                  <span class="text-zinc-300">{key.description || "—"}</span>
                </:col>
                <:col :let={key} label="Group">
                  <span class="text-zinc-400">{key.group || "default"}</span>
                </:col>
                <:col :let={key} label="Reusable">
                  <.status_badge status={if key.reusable, do: "success", else: "pending"} />
                </:col>
                <:col :let={key} label="Uses">
                  <span class="text-xs text-zinc-400">{key.uses_count}</span>
                </:col>
                <:col :let={key} label="Last used">
                  <span class="text-xs text-zinc-400">{relative_time(key.last_used_at)}</span>
                </:col>
                <:action :let={key}>
                  <%= cond do %>
                    <% key.revoked_at -> %>
                      <span class="text-xs text-zinc-500">revoked</span>
                    <% Permissions.can?(assigns, :manage_auth_keys) -> %>
                      <button
                        phx-click="revoke"
                        phx-value-id={key.id}
                        data-confirm="Revoke this auth key? Existing runners are not affected; new registrations will fail."
                        class="rounded px-2 py-1 text-xs font-medium text-rose-300 ring-1 ring-rose-500/30 hover:bg-rose-500/10"
                      >
                        Revoke
                      </button>
                    <% true -> %>
                      <span></span>
                  <% end %>
                </:action>
              </.list_table>
            </div>
          <% end %>
        </.card>
      </div>
    </.dashboard_shell>
    """
  end

end
