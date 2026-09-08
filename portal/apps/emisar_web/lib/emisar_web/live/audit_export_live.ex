defmodule EmisarWeb.AuditExportLive do
  @moduledoc """
  SIEM export configuration — mint/revoke the admin-only `:audit_export`
  tokens and point a collector at `/api/audit`. Split off the audit log
  itself: export CONFIG is a one-time admin task, not part of reading
  the trail, and it sat stranded below hundreds of rows there.
  """
  use EmisarWeb, :live_view
  alias Emisar.{ApiKeys, Billing}
  alias EmisarWeb.{LiveTable, Permissions, URLHelpers}
  alias Phoenix.LiveView.JS

  def mount(_params, _session, socket) do
    if ApiKeys.subject_can_manage_api_keys?(socket.assigns.current_subject) do
      mount_export(socket)
    else
      {:ok,
       socket
       |> put_flash(:error, "You need an owner or admin role to manage export tokens.")
       |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/audit")}
    end
  end

  defp mount_export(socket) do
    if connected?(socket) do
      # Live token list — minting/revoking (here or elsewhere) flows via
      # api_key.* broadcasts.
      ApiKeys.subscribe_account_api_keys(socket.assigns.current_account.id)
    end

    {:ok,
     socket
     |> assign(:page_title, "SIEM export")
     |> assign(
       :continuous_export_available?,
       Billing.audit_export_available?(socket.assigns.current_account)
     )
     |> assign(:export_secret, nil)
     |> assign(:base_audit_url, URLHelpers.derive_base_url(socket) <> "/api/audit")}
  end

  def handle_params(params, _uri, socket) do
    # Pagination is URL-driven; token creation and PubSub refresh the same page.
    # There is deliberately no default status filter: revoked tokens stay visible.
    socket = assign(socket, :filter_params, Map.take(params, ["after", "before"]))

    if connected?(socket) do
      {:noreply, assign_export_keys(socket)}
    else
      {:noreply, empty_export_keys(socket, false)}
    end
  end

  def handle_info({:list_changed, :api_key, _event_type, _id}, socket),
    do: {:noreply, assign_export_keys(socket)}

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("revoke_export_key", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      ApiKeys.subject_can_manage_api_keys?(socket.assigns.current_subject),
      fn s ->
        # A denial is a value here, not a crash: a role reduced in another tab
        # returns {:error, :unauthorized}, which used to kill the socket.
        with {:ok, key} <- ApiKeys.fetch_api_key_by_id(id, s.assigns.current_subject),
             {:ok, key} <- only_audit_export_key(key),
             {:ok, _revoked} <- ApiKeys.revoke_api_key(key, s.assigns.current_subject) do
          {:noreply, s |> put_flash(:info, "Export token revoked.") |> assign_export_keys()}
        else
          {:error, :not_found} ->
            {:noreply, s}

          {:error, _} ->
            {:noreply, put_flash(s, :error, "Couldn't revoke the export token. Try again.")}
        end
      end
    )
  end

  # A crafted event that drops a required key would otherwise match no clause
  # and crash the socket, taking the page's unsaved state with it. Every
  # mutating handler on this page ends in this no-op.
  def handle_event("revoke_export_key", _params, socket), do: {:noreply, socket}

  def handle_event("create_export_key", _params, socket) do
    # Audit-export keys are admin-only AND a distinct credential KIND from MCP
    # keys: `kind: :audit_export` is what authorizes `/api/audit` (an agent key
    # gets a 403 there, and vice-versa), and they live here rather than the
    # agents page so SIEM export isn't mixed in with the LLM-bridge use case.
    Permissions.gated(
      socket,
      ApiKeys.subject_can_manage_api_keys?(socket.assigns.current_subject),
      fn s ->
        attrs = %{
          name: "Audit export — #{Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")}",
          description: "Read-only token for shipping audit events to a SIEM.",
          kind: :audit_export
        }

        case ApiKeys.create_key(attrs, s.assigns.current_subject) do
          {:ok, raw, _key} ->
            {:noreply, s |> assign(:export_secret, raw) |> assign_export_keys()}

          # The mount check already bounced an ineligible plan; this covers an
          # entitlement withdrawn while the page was open.
          {:error, :audit_export_not_available} ->
            {:noreply,
             s
             |> put_flash(:info, "Audit export is available on the Team plan.")
             |> push_navigate(to: ~p"/app/#{s.assigns.current_account}/settings/billing")}

          {:error, _} ->
            {:noreply, put_flash(s, :error, "Couldn't create the export token. Try again.")}
        end
      end
    )
  end

  def handle_event("dismiss_export_secret", _params, socket),
    do: {:noreply, assign(socket, :export_secret, nil)}

  defp assign_export_keys(socket) do
    opts = LiveTable.params_to_opts(socket.assigns.filter_params, [])

    case ApiKeys.list_audit_export_keys_for_account(
           socket.assigns.current_subject,
           Keyword.put(opts, :preload, [:created_by])
         ) do
      {:ok, keys, metadata} ->
        socket
        |> assign(:export_keys, keys)
        |> assign(:metadata, metadata)
        |> assign(:load_error?, false)

      {:error, _reason} ->
        empty_export_keys(socket, true)
    end
  end

  defp empty_export_keys(socket, load_error?) do
    socket
    |> assign(:export_keys, [])
    |> assign(:metadata, %Emisar.Repo.Paginator.Metadata{count: 0, limit: 0})
    |> assign(:load_error?, load_error?)
  end

  # This page lists and mints only :audit_export tokens, so revoke narrows to that
  # same kind (like the list does): a crafted id for a same-account MCP agent key
  # this list never shows reads as a missing row and is never revoked from here.
  defp only_audit_export_key(%{kind: :audit_export} = key), do: {:ok, key}
  defp only_audit_export_key(_key), do: {:error, :not_found}

  def render(assigns) do
    ~H"""
    <.console_shell
      chrome={@shell_chrome}
      current_membership={@current_membership}
      current_subject={@current_subject}
      current_user={@current_user}
      current_account={@current_account}
      section={:audit}
      width={:table}
    >
      <:title>
        <.back_link navigate={~p"/app/#{@current_account}/audit"}>Audit log</.back_link> SIEM export
      </:title>

      <.page_intro>
        Export audit events to your SIEM for independent, long-term retention.
        Manage the read-only tokens your collector uses to connect.
        <.doc_link href={~p"/docs/audit-and-siem#token"}>SIEM export docs</.doc_link>
      </.page_intro>

      <div class="grid grid-cols-1 gap-x-10 gap-y-8 xl:grid-cols-[minmax(0,1fr)_22rem] xl:items-start">
        <section id="siem-export">
          <.callout
            :if={not @continuous_export_available?}
            tone={:amber}
            icon="state.warning"
            title="SIEM export unavailable"
            class="mb-6"
          >
            Your current plan doesn't include SIEM export. Existing tokens can't read events,
            but you can still revoke them.
            <.link
              navigate={~p"/app/#{@current_account}/settings/billing"}
              class="font-medium text-brand-400 hover:text-brand-300"
            >View plans</.link>
          </.callout>
          <.section_header title="Export tokens">
            <:actions>
              <.button
                :if={@continuous_export_available? and is_nil(@export_secret)}
                variant={:secondary}
                size={:md}
                class="shrink-0"
                type="button"
                icon="identity.credential"
                phx-click="create_export_key"
              >
                Create export token
              </.button>
            </:actions>
          </.section_header>

          <%!-- One-shot reveal in the shared naked single-secret grammar. The
               raw secret only ever exists in the socket assigns; a refresh
               hides it for good. --%>
          <div :if={@export_secret}>
            <.event_block
              icon="identity.credential"
              tone={:amber}
              title="Export token created"
            >
              <:body>
                Save this read-only token in your collector's configuration before closing this
                message. You won't be able to view it again.
              </:body>

              <.code_panel
                id="export-secret"
                label="Audit export token"
                copy
                copy_label="Copy token"
                code={@export_secret}
                class="mt-6"
              />

              <.code_panel
                id="export-secret-use"
                label="Test your token"
                annotation="contains your token"
                copy
                code={"curl -H \"Authorization: Bearer #{@export_secret}\" #{@base_audit_url}"}
                class="mt-6"
              />

              <div class="mt-6">
                <.button phx-click="dismiss_export_secret" variant={:secondary}>
                  I've saved the token
                </.button>
              </div>
            </.event_block>
          </div>

          <%!-- Existing export tokens — listed with revoke. The agents page
               filters these out so SIEM-export tokens live here exclusively. --%>
          <LiveTable.live_table
            id="export-keys"
            path={~p"/app/#{@current_account}/audit/export"}
            rows={@export_keys}
            metadata={@metadata}
            filter_params={@filter_params}
            layout={:cards}
            wrapper_class="divide-y divide-zinc-800/70 border-t border-zinc-800/70"
          >
            <:item :let={key}>
              <.list_row id={"export-key-#{key.id}"} padding="py-4">
                <:title>
                  <span class="truncate text-sm font-medium text-zinc-100">{key.name}</span>
                </:title>
                <:chips>
                  <.chip tone={:neutral}>Read-only</.chip>
                  <.chip :if={key.revoked_at} tone={:rose}>Revoked</.chip>
                </:chips>
                <:meta>
                  <.meta_line class="text-[11px]">
                    <:seg mono>{key.key_prefix}…</:seg>
                    <:seg>
                      last used{" "}<.local_time
                        id={"export-key-used-#{key.id}"}
                        value={key.last_used_at}
                        mode={:relative}
                        placeholder="never"
                      />
                    </:seg>
                    <:seg :if={key.created_by}>by {key.created_by.email}</:seg>
                  </.meta_line>
                </:meta>
                <:actions>
                  <.confirm_button
                    :if={is_nil(key.revoked_at)}
                    id={"revoke-export-#{key.id}"}
                    title="Revoke this export token?"
                    confirm_label="Revoke"
                    variant={:secondary}
                    tone={:rose}
                    size={:sm}
                    class="shrink-0"
                    on_confirm={JS.push("revoke_export_key", value: %{id: key.id})}
                  >
                    <:body>
                      Collectors using this token will lose access to audit events.
                      Events already exported are not affected.
                    </:body>
                    Revoke
                  </.confirm_button>
                </:actions>
              </.list_row>
            </:item>
            <:empty>
              <%= cond do %>
                <% not connected?(@socket) -> %>
                  <.loading_state />
                <% @load_error? -> %>
                  <.callout tone={:rose} title="Couldn't load export tokens">
                    <.link
                      patch={~p"/app/#{@current_account}/audit/export"}
                      class="font-medium text-brand-400 hover:text-brand-300"
                    >
                      {if @filter_params == %{}, do: "Try again", else: "Back to first page"}
                    </.link>
                  </.callout>
                <% @continuous_export_available? and is_nil(@export_secret) -> %>
                  <.empty_state icon="identity.credential" title="No export tokens yet">
                    Create a token to connect your SIEM or log collector.
                  </.empty_state>
                <% true -> %>
              <% end %>
            </:empty>
          </LiveTable.live_table>
        </section>

        <.docs_rail title="Connect your SIEM">
          <p>
            Configure your SIEM or log collector to request events from this endpoint using an
            export token. Each event is returned as one line of JSON (NDJSON).
          </p>
          <.code_panel
            id="audit-export-endpoint"
            label="Endpoint"
            copy
            copy_label="Copy endpoint"
            code={@base_audit_url}
          />
          <p>
            Save the cursor returned with each batch to continue where you left off.
            <.doc_link href={~p"/docs/audit-and-siem#polling"}>Collector setup</.doc_link>
          </p>
          <p>
            To replace a token, create a new one, update your collector, and confirm it works
            before revoking the old token.
            <.doc_link href={~p"/docs/credentials#audit-tokens"}>Token rotation</.doc_link>
          </p>
        </.docs_rail>
      </div>
    </.console_shell>
    """
  end
end
