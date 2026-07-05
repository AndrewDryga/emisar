defmodule EmisarWeb.AuditExportLive do
  @moduledoc """
  SIEM export configuration — mint/revoke the admin-only `:audit_export`
  tokens and point a collector at `/api/audit`. Split off the audit log
  itself: streaming CONFIG is a one-time admin task, not part of reading
  the trail, and it sat stranded below hundreds of rows there.
  """
  use EmisarWeb, :live_view
  alias Emisar.{ApiKeys, Billing}
  alias EmisarWeb.{Permissions, UrlHelpers}
  alias Phoenix.LiveView.JS

  def mount(_params, _session, socket) do
    cond do
      not Billing.audit_export_available?(socket.assigns.current_account) ->
        # Export (this SIEM feed and the CSV download alike) is Team+ — the
        # console trail stays on every plan; taking the data OUT is paid.
        {:ok,
         socket
         |> put_flash(:info, "Audit export is available on the Team plan.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/settings/billing")}

      not ApiKeys.subject_can_manage_api_keys?(socket.assigns.current_subject) ->
        {:ok,
         socket
         |> put_flash(:info, "Managing export tokens needs an admin role.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/audit")}

      true ->
        mount_export(socket)
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
     |> assign(:export_secret, nil)
     |> assign(:base_audit_url, UrlHelpers.derive_base_url(socket) <> "/api/audit")
     |> assign_export_keys()}
  end

  def handle_info({:list_changed, :api_key, _event_type, _id}, socket),
    do: {:noreply, assign_export_keys(socket)}

  def handle_info(_, socket), do: {:noreply, socket}

  def handle_event("revoke_export_key", %{"id" => id}, socket) do
    Permissions.gated(
      socket,
      ApiKeys.subject_can_manage_api_keys?(socket.assigns.current_subject),
      fn s ->
        case ApiKeys.fetch_api_key_by_id(id, s.assigns.current_subject) do
          {:ok, key} ->
            {:ok, _} = ApiKeys.revoke_api_key(key, s.assigns.current_subject)
            {:noreply, s |> put_flash(:info, "Export token revoked.") |> assign_export_keys()}

          {:error, _} ->
            {:noreply, s}
        end
      end
    )
  end

  def handle_event("create_export_key", _params, socket) do
    # Audit-export keys are admin-only AND a distinct credential KIND from MCP
    # keys: `kind: :audit_export` is what authorizes `/api/audit` (an MCP key
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

          {:error, _} ->
            {:noreply, put_flash(s, :error, "Could not mint the export key.")}
        end
      end
    )
  end

  def handle_event("dismiss_export_secret", _params, socket),
    do: {:noreply, assign(socket, :export_secret, nil)}

  defp assign_export_keys(socket) do
    case ApiKeys.list_audit_export_keys_for_account(socket.assigns.current_subject,
           page_size: 50,
           preload: [:created_by]
         ) do
      {:ok, keys, _meta} -> assign(socket, :export_keys, keys)
      _ -> assign(socket, :export_keys, [])
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:audit}
      width={:table}
    >
      <:title>
        <.back_link navigate={~p"/app/#{@current_account}/audit"}>Audit log</.back_link> SIEM export
      </:title>

      <.page_intro>
        Stream audit events as NDJSON to your SIEM for independent, long-term
        retention. Mint a read-only export token, then point your collector at <code class="font-mono text-zinc-300">{@base_audit_url}</code>.
        <.doc_link href="/docs/audit-and-siem">Audit log docs</.doc_link>
      </.page_intro>

      <%!-- CONTENT ON CANVAS (the keys-page grammar): a section header with
           the mint action, hairline token rows below — the panel island died
           with the old design. The one box left is the shown-once secret. --%>
      <section id="siem-export">
        <.section_header title="Export tokens">
          <:subtitle>
            Read-only, admin-minted, revocable — separate from the LLM-agent keys.
          </:subtitle>
          <:actions>
            <.button
              :if={is_nil(@export_secret)}
              variant={:secondary}
              size={:md}
              class="shrink-0"
              type="button"
              icon="hero-key"
              phx-click="create_export_key"
            >
              Mint export token
            </.button>
          </:actions>
        </.section_header>

        <%!-- One-shot reveal via the shared <.secret_reveal> — the single
             reviewed shown-once surface (same as agents + install). The raw
             secret only ever exists in the socket assigns; a refresh hides it
             for good. --%>
        <.secret_reveal
          :if={@export_secret}
          title="Copy this token now — we won't show it again"
          secret={@export_secret}
          on_dismiss="dismiss_export_secret"
        >
          A read-only token for shipping audit events to a SIEM.
          <:install_command label="Use with">
            curl -H "Authorization: Bearer {@export_secret}" {@base_audit_url}
          </:install_command>
        </.secret_reveal>

        <%!-- Existing export tokens — listed with revoke. The agents page
             filters these out so SIEM-export tokens live here exclusively. --%>
        <div :if={@export_keys != []} class="mt-2">
          <ul class="divide-y divide-zinc-800/70 border-t border-zinc-800/70">
            <.list_row :for={key <- @export_keys} padding="py-4">
              <:title>
                <span class="truncate text-sm font-medium text-zinc-100">{key.name}</span>
              </:title>
              <:chips>
                <.chip tone={:neutral}>read-only</.chip>
                <.chip :if={key.revoked_at} tone={:rose}>revoked</.chip>
              </:chips>
              <:meta>
                <.meta_line class="text-[11px]">
                  <:seg mono>{key.key_prefix}…</:seg>
                  <:seg>
                    last used{" "}<.local_time
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
                  <:body>Any active SIEM collector using it will start receiving 401s.</:body>
                  Revoke
                </.confirm_button>
              </:actions>
            </.list_row>
          </ul>
        </div>
      </section>
    </.dashboard_shell>
    """
  end
end
