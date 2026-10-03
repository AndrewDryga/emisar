defmodule EmisarWeb.AcceptInvitationLive do
  @moduledoc """
  Endpoint of the team-invitation flow. An invitation names an email address
  and a pending Member; whoever proves that address in this browser joins as
  that Member.

  Two states: the invitation is unavailable (expired, revoked, or already
  used), or the name form. Submitting the form posts to
  `UserSessionController.invitation_start`, which emails the invited address a
  code; using that code in this browser accepts the invitation and signs in to
  the workspace, in one step, so a forwarded link changes nothing. Where the
  workspace signs in only through SSO, the code proves the address and the
  workspace's sign-in page continues the acceptance at its identity provider.
  Other workspace sessions in this browser are irrelevant: the invitation adds
  one more.
  """
  use EmisarWeb, :live_view
  alias Emisar.Accounts
  alias EmisarWeb.LiveForm

  def mount(%{"token" => token}, _session, socket) do
    case Accounts.fetch_invitation_by_token(token, preload: [:account]) do
      # A dead link renders its state ON the page (never redirect + flash —
      # the inline-errors house rule) with a heading that names what happened.
      # The two states deliberately share one render: acceptance burns the
      # token digest, so "already used" is indistinguishable from garbage and
      # the copy says "no longer available" instead of guessing. Neither state
      # names the account — a stale link's bearer learns nothing.
      {:error, reason} when reason in [:not_found, :expired] ->
        {:ok, assign_invitation_unavailable(socket, reason)}

      {:ok, membership} ->
        {:ok,
         socket
         |> assign(:page_title, "Join #{membership.account.name}")
         |> assign(:membership, membership)
         |> assign(:token, token)
         |> assign(:trigger_submit, false)
         |> assign_form(Accounts.change_member_profile(membership))
         |> assign(:state, :name_form)}
    end
  end

  defp invitation_error_copy(:expired) do
    {"Invitation expired",
     "This invitation's link has expired. Ask whoever invited you to send a fresh one."}
  end

  defp invitation_error_copy(:not_found) do
    {"Invitation unavailable",
     "This invitation link isn't valid or is no longer available. " <>
       "Ask whoever invited you to send a fresh one."}
  end

  defp assign_invitation_unavailable(socket, reason) do
    {title, body} = invitation_error_copy(reason)

    socket
    |> assign(:page_title, title)
    |> assign(:error_title, title)
    |> assign(:error_body, body)
    |> assign(:state, :invitation_unavailable)
  end

  def render(%{state: :invitation_unavailable} = assigns) do
    ~H"""
    <.auth_layout title={@error_title}>
      <div class="space-y-4 text-sm text-zinc-400">
        <p>{@error_body}</p>

        <.button navigate={~p"/sign_in"} class="mt-2 w-full">
          Go to sign in
        </.button>
      </div>
    </.auth_layout>
    """
  end

  def render(%{state: :name_form} = assigns) do
    ~H"""
    <.auth_layout title={"Join #{@membership.account.name}"}>
      <p class="mb-6 text-sm text-zinc-400">
        You've been invited to join
        <span class="font-semibold text-zinc-200">{@membership.account.name}</span>
        as <.chip>{Emisar.Auth.role_label(@membership.role)}</.chip>.
      </p>

      <%!-- On accept we flip `trigger_submit` and the form POSTs the name to the
           invitation's code request, which emails the invited address; the
           invitation is accepted when that code is used in this browser. --%>
      <.simple_form
        for={@form}
        id="accept_form"
        action={~p"/accept_invitation/#{@token}"}
        method="post"
        phx-change="validate"
        phx-submit="accept"
        phx-trigger-action={@trigger_submit}
      >
        <%!-- Naked meta field (the detail-page key+value grammar) — the box
             around it was an island (§8.1). --%>
        <div>
          <div class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
            Joining as
          </div>
          <div class="mt-1 font-mono text-sm text-zinc-200">{@membership.email}</div>
        </div>

        <.input
          field={@form[:display_name]}
          type="text"
          label="Your name in this workspace"
          autocomplete="name"
          required
        />

        <p class="text-sm text-zinc-400">
          We'll email a sign-in link and a 6-character code to this address. You join when you use one of them in this browser.
        </p>

        <:actions>
          <.button phx-disable-with="Joining..." class="w-full">
            Accept invitation
          </.button>
        </:actions>
      </.simple_form>
    </.auth_layout>
    """
  end

  # IL-15: the rendered branch is not the gate. A crafted push can name any
  # event from any state, so each handler declares the state it belongs to and
  # everything else is a no-op — an unavailable invitation has no `membership`,
  # `token` or `form` assigned at all. The handlers write nothing; the code
  # request and its completion recheck the invitation under their locks.
  def handle_event(
        "validate",
        %{"member" => params} = event,
        %{assigns: %{state: :name_form}} = socket
      ) do
    changeset =
      socket.assigns.membership
      |> Accounts.change_member_profile(params)
      |> LiveForm.on_change(event)

    {:noreply, assign_form(socket, changeset)}
  end

  # Checks the name and that the invitation is still pending, and writes
  # nothing: the form then asks for the invited address's code, and only using
  # that code in this browser accepts.
  def handle_event("accept", %{"member" => attrs}, %{assigns: %{state: :name_form}} = socket) do
    case Accounts.prepare_invitation_acceptance(socket.assigns.token, attrs) do
      {:ok, _address, _intent} ->
        {:noreply, assign(socket, :trigger_submit, true)}

      # Field errors (e.g. a missing name) render inline on the form.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}

      # The invitation was accepted, revoked, or expired between mount and this
      # submit. That's terminal — transition to the unavailable state a fresh
      # mount would render, never a flash over a form that can no longer succeed.
      {:error, reason} when reason in [:not_found, :expired] ->
        {:noreply, assign_invitation_unavailable(socket, reason)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "member"))
end
