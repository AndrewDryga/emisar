defmodule EmisarWeb.ResetPasswordLive do
  use EmisarWeb, :live_view

  alias Emisar.{Accounts, Auth, Mailers}

  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Reset your password")
      |> assign(:sent_to, nil)
      |> assign(:reset_token, params["token"])
      |> assign(:request_form, to_form(%{"email" => ""}, as: "user"))
      |> assign(:reset_form, to_form(%{"password" => "", "password_confirmation" => ""}, as: "user"))

    {:ok, socket}
  end

  def render(%{reset_token: token} = assigns) when is_binary(token) do
    ~H"""
    <.auth_layout title="Choose a new password">
      <p class="mb-6 text-sm text-zinc-400">
        Use at least 12 characters. Mix in numbers or symbols for extra safety.
      </p>

      <.simple_form for={@reset_form} id="reset_form" phx-submit="reset">
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
          <p>If <span class="font-mono">{@sent_to}</span> is registered, a reset link is on its way.</p>
        </div>
      <% else %>
        <p class="mb-6 text-sm text-zinc-400">
          Enter the email on your account. We'll send a reset link if it exists.
        </p>

        <.simple_form for={@request_form} id="request_form" phx-submit="request">
          <.input field={@request_form[:email]} type="email" label="Work email" required />

          <:actions>
            <.button phx-disable-with="Sending..." class="w-full">Email reset link</.button>
          </:actions>
        </.simple_form>
      <% end %>

      <p class="mt-6 text-center text-sm text-zinc-400">
        Remembered it?
        <.link href={~p"/sign_in"} class="font-medium text-indigo-400 hover:text-indigo-300">Sign in</.link>
      </p>
    </.auth_layout>
    """
  end

  def handle_event("request", %{"user" => %{"email" => email}}, socket) do
    # 3 reset requests per email per 10 min (same shape as magic-link).
    case EmisarWeb.RateLimiter.check("pw_reset:" <> String.downcase(email || ""), 3, 600_000) do
      :ok ->
        if user = Accounts.get_user_by_email(email) do
          token = Auth.issue_password_reset_token(user)
          Mailers.UserNotifier.deliver_password_reset(user, token)
        end

        {:noreply, assign(socket, :sent_to, email)}

      {:error, :rate_limited, _ms} ->
        # Same UX as success — don't leak that the address is throttled.
        {:noreply, assign(socket, :sent_to, email)}
    end
  end

  def handle_event("reset", %{"user" => %{"password" => password, "password_confirmation" => confirmation}}, socket) do
    cond do
      password != confirmation ->
        {:noreply, put_flash(socket, :error, "Passwords don't match.")}

      String.length(password) < 12 ->
        {:noreply, put_flash(socket, :error, "Use at least 12 characters.")}

      true ->
        case Auth.reset_user_password(socket.assigns.reset_token, password) do
          {:ok, _user} ->
            {:noreply,
             socket
             |> put_flash(:info, "Password updated. Sign in below.")
             |> push_navigate(to: ~p"/sign_in")}

          {:error, _} ->
            {:noreply,
             socket
             |> put_flash(:error, "That link expired. Request a new one.")
             |> push_navigate(to: ~p"/reset_password")}
        end
    end
  end
end
