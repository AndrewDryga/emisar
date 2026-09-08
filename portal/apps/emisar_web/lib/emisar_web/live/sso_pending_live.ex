defmodule EmisarWeb.SSOPendingLive do
  @moduledoc """
  Where an SSO sign-in waits for administrator approval, including identity
  links for existing members. Keyed by the link-request id the callback stashed
  in the session after provider authentication. Subscribing to that request
  lets approval restart sign-in and dismissal update this page without refresh.
  """
  use EmisarWeb, :live_view
  alias Emisar.SSO

  def mount(_params, session, socket) do
    request_id = session["sso_pending_request"]

    case request_id && SSO.fetch_pending_link_request(request_id) do
      {:ok, request} ->
        if connected?(socket), do: SSO.subscribe_link_request(request.id)

        {:ok,
         socket
         |> assign(:page_title, "Access pending")
         |> assign(:request, request)
         |> assign(:invitation_pending?, SSO.link_request_invitation_pending?(request))
         |> assign(:status, :pending)}

      _ ->
        # No stashed request, or it was already approved/dismissed — nothing to
        # wait on. Send them to sign in (an approved person can sign in now).
        {:ok, redirect(socket, to: ~p"/sign_in")}
    end
  end

  # Approved: restart provider sign-in. The provider may still require a prompt;
  # the normal callback rechecks the current connection and membership state.
  def handle_info({:sso_link_request, :approved, %{provider_id: provider_id}}, socket) do
    {:noreply, redirect(socket, to: ~p"/sign_in/sso/#{provider_id}")}
  end

  def handle_info({:sso_link_request, :dismissed, _payload}, socket) do
    {:noreply, assign(socket, :status, :dismissed)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.auth_layout title="Access pending">
      <div :if={@status == :pending} class="space-y-6">
        <%!-- Naked dot-led wait line (the install wizard's wait grammar) — a
             box around a status line is the island §8.1 bans. --%>
        <div class="flex items-center gap-3">
          <.status_dot tone={:amber} size={:lg} />
          <p :if={not @invitation_pending?} class="text-sm text-zinc-300">
            An administrator at <span class="font-medium text-zinc-100">{@request.account.name}</span>
            must approve this sign-in.
          </p>
          <p :if={@invitation_pending?} class="text-sm text-zinc-300">
            Accept your invitation to
            <span class="font-medium text-zinc-100">{@request.account.name}</span>
            before an administrator can approve this sign-in.
          </p>
        </div>

        <p :if={not @invitation_pending?} class="text-sm leading-relaxed text-zinc-400">
          Your identity provider signed you in as <span class="break-all font-medium text-zinc-200">{@request.email}</span>.
          Keep this page open to continue after approval.
        </p>

        <p :if={@invitation_pending?} class="text-sm leading-relaxed text-zinc-400">
          Open the workspace invitation sent to
          <span class="font-medium text-zinc-200">{@request.email}</span>
          and accept it. Then keep this page open to continue after an administrator approves
          this sign-in.
        </p>

        <p class="text-xs leading-relaxed text-zinc-400">
          If this page loses its connection or you close it, sign in again to check for approval.
        </p>

        <.button variant={:secondary} href={~p"/sign_in"} class="w-full">
          Back to sign in
        </.button>
      </div>

      <div :if={@status == :dismissed} class="space-y-6">
        <.callout tone={:rose} icon="state.denied">
          Your sign-in request was declined.
        </.callout>

        <p class="text-sm leading-relaxed text-zinc-400">
          An administrator at <span class="font-medium text-zinc-200">{@request.account.name}</span>
          dismissed your request. If you think that's a mistake, reach out to them directly.
        </p>

        <.button variant={:secondary} href={~p"/sign_in"} class="w-full">
          Back to sign in
        </.button>
      </div>
    </.auth_layout>
    """
  end
end
