defmodule EmisarWeb.ServiceAccountKeyLive do
  @moduledoc """
  Creates an API key that acts as one service account, opened from its row on
  the Service accounts page. It walks the AI agents custom key's steps — name
  the key, save the secret it shows once, then point the app at the MCP
  endpoint — so a person connecting their own agent never meets a choice of
  who the key acts as.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, ApiKeys}
  alias EmisarWeb.{LiveForm, URLHelpers}

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Create an API key")
     |> assign(:service_account, nil)
     |> assign(:name, nil)
     |> assign(:secret, nil)
     |> assign(:error, nil)
     |> assign(:base_url, URLHelpers.derive_base_url(socket))
     |> assign_form(ApiKeys.change_key(default_params()))}
  end

  def handle_params(%{"membership_id" => id}, _uri, socket) do
    if connected?(socket) do
      case Accounts.fetch_team_member_facts(id, socket.assigns.current_subject) do
        {:ok, %{service_account?: true, disabled?: false, manageable?: true} = facts} ->
          {:noreply,
           socket
           |> assign(:service_account, facts.membership)
           |> assign(:name, Accounts.member_display_name(facts.membership))}

        _unavailable ->
          {:noreply,
           socket
           |> put_flash(:error, "That service account isn't available to you.")
           |> push_navigate(to: service_accounts_path(socket))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate", %{"api_key" => params} = event, socket) when is_map(params) do
    changeset = params |> ApiKeys.change_key() |> LiveForm.on_change(event)
    {:noreply, assign_form(socket, changeset)}
  end

  # One page mints one key: once its secret is on screen the form is gone, and
  # a replayed submit is ignored rather than minting a second key.
  def handle_event(
        "create",
        %{"api_key" => params},
        %{assigns: %{service_account: %Accounts.Membership{} = service_account, secret: nil}} =
          socket
      )
      when is_map(params) do
    socket = assign_form(socket, ApiKeys.change_key(params))
    subject = socket.assigns.current_subject

    case ApiKeys.create_service_account_key(service_account.id, params, subject) do
      {:ok, raw, _key} ->
        {:noreply, socket |> assign(:secret, raw) |> assign(:error, nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, socket |> assign_form(changeset) |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, create_error(reason))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp create_error(:not_found),
    do: "This service account is no longer available. It may have been suspended or removed."

  defp create_error(:runner_access_exceeds_subject) do
    "This service account can reach runners or packs you can't, so you can't create a key for it."
  end

  defp create_error(:unauthorized),
    do: "Only owners and admins can create keys for service accounts."

  defp create_error(_reason), do: "Couldn't create the key. Try again."

  defp default_params, do: %{"name" => "", "description" => "", "expires_at" => ""}

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "api_key"))

  defp service_accounts_path(socket),
    do: ~p"/app/#{socket.assigns.current_account}/settings/service-accounts"

  def render(assigns) do
    ~H"""
    <.console_shell
      chrome={@shell_chrome}
      current_membership={@current_membership}
      current_subject={@current_subject}
      current_account={@current_account}
      section={:service_accounts}
      width={:table}
    >
      <:title>
        <.back_link navigate={~p"/app/#{@current_account}/settings/service-accounts"}>
          Service accounts
        </.back_link>
        {if @service_account,
          do: "Create an API key for #{@name}",
          else: "Create an API key"}
      </:title>
      <.loading_state :if={is_nil(@service_account)} />
      <div :if={@service_account} class="max-w-2xl">
        <%= if @secret do %>
          <section id="service-account-key-save-step" class="space-y-4">
            <.step_header step={1} title="Save your key" />
            <.new_api_key id="service-account-key-secret" secret={@secret} />
          </section>

          <section id="service-account-key-connect-step" class="mt-8">
            <.step_header step={2} title="Connect your app">
              <:subtitle>Add an MCP server in your app and choose Streamable HTTP.</:subtitle>
            </.step_header>
            <div class="ml-6 max-w-prose">
              <.mcp_http_setup id="service-account-key-rpc-url" base_url={@base_url} />
            </div>
          </section>

          <div class="mt-8 flex flex-wrap items-center gap-3">
            <.button navigate={~p"/app/#{@current_account}/settings/service-accounts"}>
              Done
            </.button>
            <.button
              navigate={~p"/app/#{@current_account}/agents?#{[owner: [@service_account.id]]}"}
              variant={:secondary}
            >
              View connections
            </.button>
          </div>
        <% else %>
          <section id="service-account-key-create-step">
            <.step_header step={1} title="Create a key" />
            <p class="text-sm leading-relaxed text-zinc-400">
              An app that uses this key acts as <span class="font-medium text-zinc-200">{@name}</span>. It gets the service
              account's runner and pack access. The audit log attributes its requests to
              the service account.
            </p>

            <.simple_form
              for={@form}
              id="api_key_form"
              phx-change="validate"
              phx-submit="create"
              class="mt-6 space-y-5"
            >
              <.api_key_fields
                form={@form}
                name_placeholder={"e.g. #{@name} in production"}
              />
              <.error :if={@error}>{@error}</.error>
              <:actions>
                <.button phx-disable-with="Creating...">Create key</.button>
                <.button
                  navigate={~p"/app/#{@current_account}/settings/service-accounts"}
                  variant={:ghost}
                >
                  Cancel
                </.button>
              </:actions>
            </.simple_form>
          </section>
        <% end %>
      </div>
    </.console_shell>
    """
  end
end
