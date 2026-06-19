defmodule EmisarWeb.ResetPasswordLive do
  use EmisarWeb, :live_view

  alias Emisar.{Auth, Mailers, Users}
  alias EmisarWeb.{RequestContext, ReturnTo, Throttle}

  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Reset your password")
      |> assign(:sent_to, nil)
      |> assign(:reset_token, params["token"])
      # A branded page threads ?return_to=/app/<slug> through the request → email →
      # reset so the operator lands back on that team's sign-in, not the generic one.
      |> assign(:return_to, ReturnTo.app_path(params["return_to"]))
      # Captured at mount — `get_connect_info/2` is mount-only, so the
      # request/reset handlers read it from this assign.
      |> assign(:request_context, RequestContext.from_socket(socket))
      |> assign(:request_form, to_form(Users.change_user(%Users.User{}), as: "user"))
      |> assign(:reset_form, to_form(Users.change_password(%Users.User{}), as: "user"))

    {:ok, socket}
  end

  def render(%{reset_token: token} = assigns) when is_binary(token) do
    ~H"""
    <.auth_layout title="Choose a new password">
      <p class="mb-6 text-sm text-zinc-400">
        Use at least 12 characters. Mix in numbers or symbols for extra safety.
      </p>

      <.simple_form
        for={@reset_form}
        id="reset_form"
        phx-change="validate_reset"
        phx-submit="reset"
      >
        <.input
          field={@reset_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          minlength="12"
          required
        />
        <.input
          field={@reset_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          minlength="12"
          required
        />

        <:actions>
          <.button phx-disable-with="Resetting..." class="w-full">Reset password</.button>
        </:actions>
      </.simple_form>
    </.auth_layout>
    """
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Reset your password">
      <%= if @sent_to do %>
        <div class="rounded-lg border border-emerald-700/40 bg-emerald-950/40 p-6 text-emerald-200">
          <p>
            If <span class="font-mono">{@sent_to}</span> is registered, a reset link is on its way.
          </p>
          <button
            phx-click="reset_form"
            class="mt-4 text-xs font-medium text-emerald-300 hover:text-emerald-100"
          >
            Use a different email →
          </button>
        </div>
      <% else %>
        <p class="mb-6 text-sm text-zinc-400">
          Enter the email on your account. We'll send a reset link if it exists.
        </p>

        <.simple_form
          for={@request_form}
          id="request_form"
          phx-change="validate_request"
          phx-submit="request"
        >
          <.input field={@request_form[:email]} type="email" label="Work email" required />

          <:actions>
            <.button phx-disable-with="Sending..." class="w-full">Email reset link</.button>
          </:actions>
        </.simple_form>
      <% end %>

      <p class="mt-6 text-center text-sm text-zinc-400">
        Remembered it?
        <.link href={~p"/sign_in"} class="font-medium text-indigo-400 hover:text-indigo-300">
          Sign in
        </.link>
      </p>
    </.auth_layout>
    """
  end

  def handle_event("reset_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:sent_to, nil)
     |> assign(:request_form, to_form(Users.change_user(%Users.User{}), as: "user"))}
  end

  def handle_event("validate_request", %{"user" => params}, socket) do
    changeset =
      %Users.User{}
      |> Users.change_user(%{"email" => params["email"] || ""})
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :request_form, to_form(changeset, as: "user"))}
  end

  def handle_event("validate_reset", %{"user" => params}, socket) do
    changeset =
      %Users.User{}
      |> Users.change_password(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :reset_form, to_form(changeset, as: "user"))}
  end

  def handle_event("request", %{"user" => %{"email" => email}}, socket) do
    # Throttle by recipient so this form can't bomb an inbox. The key is the
    # normalised email — an ETS bucket key, NOT a DB lookup (citext owns the
    # DB comparison), so the no-app-downcase rule doesn't apply. No `else`:
    # a throttled OR an unknown email both fall through to the same "sent"
    # panel below, leaking neither account existence nor the throttle.
    key = email |> to_string() |> String.trim() |> String.downcase()

    with :ok <- Throttle.check("password_reset", key, 5, 900_000),
         {:ok, user} <- Users.fetch_user_by_email(email) do
      token = Auth.issue_password_reset_token!(user, [], socket.assigns.request_context)
      Mailers.UserNotifier.deliver_password_reset(user, token, socket.assigns.return_to)
    end

    {:noreply, assign(socket, :sent_to, email)}
  end

  def handle_event("reset", %{"user" => %{"password" => password} = params}, socket) do
    # Length + confirmation-mismatch are field errors — render them inline
    # (border + message) on the right input instead of a flash.
    changeset = Users.change_password(%Users.User{}, params)

    if changeset.valid? do
      case Auth.reset_user_password(
             socket.assigns.reset_token,
             password,
             socket.assigns.request_context
           ) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "Password updated. Sign in below.")
           |> push_navigate(to: post_reset_path(socket.assigns.return_to))}

        {:error, _} ->
          {:noreply,
           socket
           |> put_flash(:error, "That link expired. Request a new one.")
           |> push_navigate(to: ~p"/reset_password")}
      end
    else
      {:noreply,
       assign(socket, :reset_form, to_form(Map.put(changeset, :action, :insert), as: "user"))}
    end
  end

  # Land back on the branded sign-in for the team the reset began on, else the
  # generic page. `return_to` is already whitelisted to `/app/<ref>` by ReturnTo.
  defp post_reset_path("/app/" <> ref), do: ~p"/app/#{ref}/sign_in"
  defp post_reset_path(_), do: ~p"/sign_in"
end
