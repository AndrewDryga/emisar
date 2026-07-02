defmodule EmisarWeb.SSOPendingLive do
  @moduledoc """
  Where a `:manual`-provisioner SSO first login waits. Instead of an error bounce,
  the person lands here — authenticated to their IdP but with no account access
  yet — while an admin approves them. Keyed by the link-request id the callback
  stashed in the session (possession is the authorization; the person isn't a
  member). Subscribing to the request lets approval re-run sign-in automatically,
  and dismissal say so, with no refresh.
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
         |> assign(:status, :pending)}

      _ ->
        # No stashed request, or it was already approved/dismissed — nothing to
        # wait on. Send them to sign in (an approved person can sign in now).
        {:ok, redirect(socket, to: ~p"/sign_in")}
    end
  end

  # Approved: the identity now exists, so re-run SSO — the person is still signed
  # in to their IdP, so it completes without a prompt and lands them in the app.
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
        <div class="flex items-center gap-3 rounded-lg bg-zinc-900/50 p-4 ring-1 ring-white/5">
          <.status_dot tone={:brand} ping size={:lg} />
          <p class="text-sm text-zinc-300">
            Waiting for an administrator at
            <span class="font-medium text-zinc-100">{@request.account.name}</span>
            to approve your access.
          </p>
        </div>

        <p class="text-sm leading-relaxed text-zinc-400">
          You've signed in through your identity provider as <span class="font-medium text-zinc-200">{@request.email}</span>, but this team has an
          admin approve each new member. Leave this page open — it signs you in automatically the
          moment they approve.
        </p>

        <p class="text-xs leading-relaxed text-zinc-500">
          Until then you can't reach anything in the account — there's nothing you need to do here.
        </p>

        <.button variant={:secondary} href={~p"/sign_in"} class="w-full">
          Back to sign in
        </.button>
      </div>

      <div :if={@status == :dismissed} class="space-y-6">
        <.callout tone={:rose} icon="hero-x-circle">
          Your access request was declined.
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
