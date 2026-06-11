defmodule EmisarWeb.AcceptInvitationLive do
  @moduledoc """
  Endpoint of the team-invitation flow.

  Three render branches:

    * Not signed in → password-set form, accepting submits + signs the
      new user in via the standard `/sign_in` controller.
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
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "That invitation expired or was already used.")
         |> push_navigate(to: ~p"/sign_in")}

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

  def render(%{state: :anonymous} = assigns) do
    ~H"""
    <.auth_layout title={"Join #{@membership.account.name}"}>
      <p class="mb-6 text-sm text-zinc-400">
        You've been invited to join
        <span class="font-semibold text-zinc-200">{@membership.account.name}</span>
        as <span class="font-mono text-indigo-300">{@membership.role}</span>.
      </p>

      <.simple_form
        for={@form}
        id="accept_form"
        action={~p"/sign_in?_action=invitation_accepted"}
        method="post"
        phx-change="validate"
        phx-submit="accept"
        phx-trigger-action={@trigger_submit}
      >
        <input type="hidden" name="user[email]" value={@membership.user.email} />

        <div class="rounded-lg border border-zinc-900 bg-zinc-950/60 p-4 text-sm">
          <div class="text-xs uppercase tracking-wider text-zinc-500">Joining as</div>
          <div class="mt-1 font-mono text-zinc-200">{@membership.user.email}</div>
        </div>

        <.input field={@form[:full_name]} type="text" label="Your name" required />
        <.input
          field={@form[:password]}
          type="password"
          label="Set a password"
          autocomplete="new-password"
          minlength="12"
          required
        />

        <:actions>
          <.button phx-disable-with="Joining..." class="w-full">
            Accept invitation <span aria-hidden="true">→</span>
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
        as <span class="font-mono text-indigo-300">{@membership.role}</span>.
      </p>

      <button
        phx-click="accept_existing"
        phx-disable-with="Accepting..."
        class="block w-full rounded-lg bg-indigo-500 px-4 py-2.5 text-center text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
      >
        Accept invitation <span aria-hidden="true">→</span>
      </button>
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

        <.link
          href={~p"/sign_out"}
          method="delete"
          class="mt-2 block w-full rounded-lg border border-rose-500/40 px-4 py-2.5 text-center text-sm font-medium text-rose-200 hover:bg-rose-500/10"
        >
          Sign out
        </.link>
      </div>
    </.auth_layout>
    """
  end

  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      socket.assigns.membership.user
      |> Users.change_user(%{
        "full_name" => params["full_name"] || "",
        "password" => params["password"] || ""
      })
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("accept", %{"user" => user_params}, socket) do
    attrs = %{
      "full_name" => user_params["full_name"] || "",
      "password" => user_params["password"] || ""
    }

    case Accounts.accept_invitation(socket.assigns.membership, attrs) do
      {:ok, _} ->
        {:noreply, assign(socket, :trigger_submit, true)}

      # Field errors (e.g. a too-short password) render inline on the form.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Could not accept the invitation.")}
    end
  end

  # Signed-in user accepting their own invitation: the user record
  # already has a password + confirmed_at, so we skip
  # User.Changeset.registration entirely and just mark the membership
  # accepted in-place.
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
