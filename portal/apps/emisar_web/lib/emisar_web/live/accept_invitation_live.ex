defmodule EmisarWeb.AcceptInvitationLive do
  @moduledoc """
  Endpoint of the team-invitation flow.

  Three render branches:

    * Not signed in → a name form; accepting provisions the member and
      emails them a magic-link sign-in (no password to set).
    * Signed in AS the invited email → one-click accept (no password
      re-entry); we mark the membership accepted and forward to /app.
    * Signed in as a DIFFERENT email → "this invite is for X, sign out
      first" with an explicit sign-out link. Previously the visitor was
      silently bounced to /app and never saw the invite.
  """
  use EmisarWeb, :live_view
  alias Emisar.Accounts
  alias Emisar.Users

  def mount(%{"token" => token}, _session, socket) do
    case Accounts.fetch_invitation_by_token(token, preload: [:account, :user]) do
      # A dead link renders its state ON the page (never redirect + flash —
      # the inline-errors house rule) with a heading that names what happened.
      # The two states deliberately share one render: acceptance burns the
      # token digest, so "already used" is indistinguishable from garbage and
      # the copy says "no longer available" instead of guessing. Neither state
      # names the account — a stale link's bearer learns nothing.
      {:error, reason} when reason in [:not_found, :expired] ->
        {title, body} = invitation_error_copy(reason)

        {:ok,
         socket
         |> assign(:page_title, title)
         |> assign(:error_title, title)
         |> assign(:error_body, body)
         |> assign(:state, :invitation_unavailable)}

      {:ok, membership} ->
        {:ok,
         socket
         |> assign(:page_title, "Join #{membership.account.name}")
         |> assign(:membership, membership)
         |> assign(:token, token)
         |> assign(:trigger_submit, false)
         |> assign_form(Users.change_user(membership.user))
         |> assign(:state, derive_state(socket, membership))}
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

  # Three possible states for the page render.
  defp derive_state(socket, membership) do
    case socket.assigns[:current_user] do
      nil ->
        :anonymous

      %{id: id} when id == membership.user_id ->
        :signed_in_match

      %{} ->
        :signed_in_mismatch
    end
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

  def render(%{state: :anonymous} = assigns) do
    ~H"""
    <.auth_layout title={"Join #{@membership.account.name}"}>
      <p class="mb-6 text-sm text-zinc-400">
        You've been invited to join
        <span class="font-semibold text-zinc-200">{@membership.account.name}</span>
        as <.chip>{@membership.role}</.chip>.
      </p>

      <%!-- On accept we flip `trigger_submit` and the form POSTs the invitee's
           email to the magic-link request, so they get a one-time sign-in link
           (no password to set). --%>
      <.simple_form
        for={@form}
        id="accept_form"
        action={~p"/sign_in/magic/start"}
        method="post"
        phx-change="validate"
        phx-submit="accept"
        phx-trigger-action={@trigger_submit}
      >
        <input type="hidden" name="user[email]" value={@membership.user.email} />

        <%!-- Naked meta field (the detail-page key+value grammar) — the box
             around it was an island (§8.1). --%>
        <div>
          <div class="text-[11px] font-semibold uppercase tracking-wider text-zinc-500">
            Joining as
          </div>
          <div class="mt-1 font-mono text-sm text-zinc-200">{@membership.user.email}</div>
        </div>

        <.input field={@form[:full_name]} type="text" label="Your name" required />

        <:actions>
          <.button phx-disable-with="Joining..." class="w-full">
            Accept &amp; email me a sign-in link <span aria-hidden="true">→</span>
          </.button>
        </:actions>
      </.simple_form>
    </.auth_layout>
    """
  end

  def render(%{state: :signed_in_match} = assigns) do
    ~H"""
    <.auth_layout title={"Join #{@membership.account.name}"}>
      <p class="mb-6 text-sm text-zinc-400">
        You're signed in as <span class="font-mono text-zinc-200">{@membership.user.email}</span>
        — accept your invitation to join
        <span class="font-semibold text-zinc-200">{@membership.account.name}</span>
        as <.chip>{@membership.role}</.chip>.
      </p>

      <.button class="w-full" phx-click="accept_existing" phx-disable-with="Accepting...">
        Accept invitation <span aria-hidden="true">→</span>
      </.button>
    </.auth_layout>
    """
  end

  def render(%{state: :signed_in_mismatch} = assigns) do
    ~H"""
    <.auth_layout title="Wrong account">
      <div class="space-y-4 text-sm text-zinc-300">
        <p>
          This invitation is for <span class="font-mono text-zinc-100">{@membership.user.email}</span>, but
          you're signed in as <span class="font-mono text-zinc-100">{@current_user.email}</span>.
        </p>
        <p class="text-zinc-400">
          Sign out first, then re-open the invitation link to accept it as {@membership.user.email}.
        </p>

        <.button
          variant={:secondary}
          tone={:rose}
          href={~p"/sign_out"}
          method="delete"
          class="mt-2 w-full"
        >
          Sign out
        </.button>
      </div>
    </.auth_layout>
    """
  end

  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      socket.assigns.membership.user
      |> Users.change_user(%{"full_name" => params["full_name"] || ""})
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("accept", %{"user" => user_params}, socket) do
    attrs = %{"full_name" => user_params["full_name"] || ""}

    case Accounts.accept_invitation(socket.assigns.membership, attrs) do
      {:ok, _} ->
        {:noreply, assign(socket, :trigger_submit, true)}

      # Field errors (e.g. a missing name) render inline on the form.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Could not accept the invitation.")}
    end
  end

  # Signed-in user accepting their own invitation: the user record
  # already exists + confirmed, so we skip provisioning entirely and
  # just mark the membership accepted in-place.
  def handle_event("accept_existing", _params, socket) do
    membership = socket.assigns.membership

    case Accounts.mark_invitation_accepted(membership, socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Welcome to #{membership.account.name}.")
         |> push_navigate(to: ~p"/app")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not accept the invitation.")}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "user"))
end
