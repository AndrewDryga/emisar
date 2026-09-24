defmodule EmisarWeb.AcceptInvitationLive do
  @moduledoc """
  Endpoint of the team-invitation flow. An invitation names an email address;
  whoever proves that address joins.

  Four render branches:

    * Not signed in → a name form; accepting links the member to the personal
      login for the invited address (created on first use) and emails it a
      magic-link sign-in (no password to set).
    * Signed in AS the invited email → accept over HTTP, then explicitly sign
      in again. Acceptance never adds the new membership to an old browser's proof.
    * Signed in as a DIFFERENT email → "this invite is for X, sign out
      first" with an explicit sign-out link. Previously the visitor was
      silently bounced to /app and never saw the invite.
    * Signed in to a workspace through single sign-on without a personal login
      → nothing here can accept for it, so sign out first, then sign in or sign
      up with the invited address.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, Auth, Users}
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
         |> assign(:state, derive_state(socket.assigns, membership))}
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

  # The page only chooses what to offer; acceptance re-checks the address.
  defp derive_state(%{current_user: %Users.User{} = user}, membership) do
    if invited_address?(user, membership),
      do: :signed_in_match,
      else: :signed_in_mismatch
  end

  # A member-only SSO session has no personal login to accept with, and this
  # browser's email sign-in only links one to its own workspace Member.
  defp derive_state(%{current_auth: %Auth.UserToken{}}, _membership), do: :member_only
  defp derive_state(_assigns, _membership), do: :anonymous

  # Both addresses are citext columns, which compare case-insensitively; so does this.
  defp invited_address?(%Users.User{email: email}, membership) when is_binary(email),
    do: String.downcase(email) == String.downcase(membership.invitation_sent_to)

  defp invited_address?(%Users.User{}, _membership), do: false

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
        as <.chip>{Emisar.Auth.role_label(@membership.role)}</.chip>.
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
        <input type="hidden" name="user[email]" value={@membership.invitation_sent_to} />
        <input type="hidden" name="return_to" value={~p"/app/#{@membership.account}"} />

        <%!-- Naked meta field (the detail-page key+value grammar) — the box
             around it was an island (§8.1). --%>
        <div>
          <div class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
            Joining as
          </div>
          <div class="mt-1 font-mono text-sm text-zinc-200">{@membership.invitation_sent_to}</div>
        </div>

        <.input
          field={@form[:display_name]}
          type="text"
          label="Your name in this workspace"
          autocomplete="name"
          required
        />

        <p class="text-sm text-zinc-400">
          We'll email you a sign-in link and a 6-character code to finish signing in.
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

  def render(%{state: :signed_in_match} = assigns) do
    ~H"""
    <.auth_layout title={"Join #{@membership.account.name}"}>
      <p class="mb-6 text-sm text-zinc-400">
        You're signed in as
        <span class="font-mono text-zinc-200">{@membership.invitation_sent_to}</span>
        — accept your invitation to join
        <span class="font-semibold text-zinc-200">{@membership.account.name}</span>
        as <.chip>{Emisar.Auth.role_label(@membership.role)}</.chip>.
      </p>

      <p class="mb-6 text-sm text-zinc-400">
        After accepting, sign in again to open this workspace. Accepting does not sign you out.
      </p>
      <.form
        for={%{}}
        id="accept_existing_form"
        action={~p"/accept_invitation/#{@token}"}
        method="post"
      >
        <.button class="w-full">Accept invitation <span aria-hidden="true">→</span></.button>
      </.form>
    </.auth_layout>
    """
  end

  def render(%{state: :signed_in_mismatch} = assigns) do
    ~H"""
    <.auth_layout title="Sign in with your invited email">
      <div class="space-y-4 text-sm text-zinc-300">
        <p>
          This invitation is for <span class="font-mono text-zinc-100">{@membership.invitation_sent_to}</span>, but
          you're signed in as <span class="font-mono text-zinc-100">{@current_user.email}</span>.
        </p>
        <p class="text-zinc-400">
          Sign out, then reopen this invitation from your email. To join with your current email
          instead, ask the sender to invite that address.
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

  def render(%{state: :member_only} = assigns) do
    ~H"""
    <.auth_layout title="Sign in with your invited email">
      <div class="space-y-4 text-sm text-zinc-300">
        <p>
          This invitation is for <span class="font-mono text-zinc-100">{@membership.invitation_sent_to}</span>, but
          this browser is signed in to a workspace through single sign-on, without a personal login.
        </p>
        <p class="text-zinc-400">
          Sign out, then reopen this invitation from your email to sign in or sign up with that address.
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

  # IL-15: the rendered branch is not the gate. A crafted push can name any
  # event from any state, so each handler declares the state it belongs to and
  # everything else is a no-op — an unavailable invitation has no `membership`,
  # `token` or `form` assigned at all. Signed-in acceptance is an HTTP form;
  # its controller and context recheck the invitation and same-user boundary.
  def handle_event(
        "validate",
        %{"member" => params} = event,
        %{assigns: %{state: :anonymous}} = socket
      ) do
    changeset =
      socket.assigns.membership
      |> Accounts.change_member_profile(params)
      |> LiveForm.on_change(event)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("accept", %{"member" => attrs}, %{assigns: %{state: :anonymous}} = socket) do
    case Accounts.accept_invitation(socket.assigns.membership, socket.assigns.token, attrs) do
      {:ok, _} ->
        {:noreply, assign(socket, :trigger_submit, true)}

      # Field errors (e.g. a missing name) render inline on the form.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}

      # The invitation was burnt, revoked, or expired between mount and this
      # submit (a second link-holder raced us, or the window lapsed). That's
      # terminal — transition to the unavailable state a fresh mount would
      # render, never a 7-second flash over a form that can no longer succeed.
      {:error, :not_found} ->
        {:noreply, assign_invitation_unavailable(socket, :not_found)}

      {:error, :already_member} ->
        {:noreply, put_flash(socket, :error, already_member_message())}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Could not accept the invitation.")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @doc "Copy for an invitation whose address already belongs to a member of that workspace."
  def already_member_message,
    do: "That email address already belongs to a member of this workspace. Sign in to open it."

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "member"))
end
