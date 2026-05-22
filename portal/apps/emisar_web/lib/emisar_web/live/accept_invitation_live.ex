defmodule EmisarWeb.AcceptInvitationLive do
  @moduledoc """
  Endpoint of the team-invitation flow.

      1. Admin invites a teammate from TeamLive →
      2. Mailer sends `/accept_invitation/:token` →
      3. This LiveView shows account name + email, asks for full_name + password →
      4. Accounts.accept_invitation/2 sets the password, clears the token,
         marks the membership accepted, confirms the user.
      5. Submitting the form posts to /sign_in?_action=invitation_accepted
         which logs them in.

  Invalid / expired tokens redirect to /sign_in with an error flash.
  """
  use EmisarWeb, :live_view

  alias Emisar.Accounts

  def mount(%{"token" => token}, _session, socket) do
    case Accounts.find_invitation_by_token(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That invitation expired or was already used.")
         |> push_navigate(to: ~p"/sign_in")}

      membership ->
        {:ok,
         socket
         |> assign(:page_title, "Join #{membership.account.name}")
         |> assign(:membership, membership)
         |> assign(:token, token)
         |> assign(:trigger_submit, false)
         |> assign(:form, to_form(%{"full_name" => "", "password" => ""}, as: "user"))}
    end
  end

  def render(assigns) do
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

  def handle_event("accept", %{"user" => user_params}, socket) do
    attrs = %{
      "full_name" => user_params["full_name"] || "",
      "password" => user_params["password"] || ""
    }

    case Accounts.accept_invitation(socket.assigns.membership, attrs) do
      {:ok, _} ->
        {:noreply, assign(socket, :trigger_submit, true)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, "Could not accept: #{format_errors(cs)}")}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Could not accept the invitation.")}
    end
  end

  defp format_errors(cs) do
    Enum.map_join(cs.errors, ", ", fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
  end
end
