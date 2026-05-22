defmodule EmisarWeb.ProfileLive do
  use EmisarWeb, :live_view

  alias Emisar.{Accounts, Auth}

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Profile")
     |> assign(:mfa_enabled?, mfa_enabled?(user))
     |> assign(:mfa_secret, nil)
     |> assign(:mfa_uri, nil)
     |> assign_profile_form(user)
     |> assign_password_form()
     |> assign_mfa_form()}
  end

  def handle_event("validate_profile", %{"profile" => params}, socket) do
    {:noreply, assign(socket, :profile_form, to_form(params, as: "profile"))}
  end

  def handle_event("save_profile", %{"profile" => params}, socket) do
    case Accounts.update_user_profile(socket.assigns.current_user, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Profile updated.")
         |> assign(:current_user, updated)
         |> assign_profile_form(updated)}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, as: "profile"))}
    end
  end

  def handle_event("change_password", %{"password" => params}, socket) do
    user = socket.assigns.current_user
    current = params["current_password"] || ""
    new = params["password"] || ""
    confirm = params["password_confirmation"] || ""

    cond do
      Auth.get_user_by_email_and_password(user.email, current) == nil ->
        {:noreply, put_flash(socket, :error, "Current password is incorrect.")}

      new != confirm ->
        {:noreply, put_flash(socket, :error, "New passwords don't match.")}

      String.length(new) < 12 ->
        {:noreply, put_flash(socket, :error, "Use at least 12 characters.")}

      true ->
        changeset = Emisar.Accounts.User.password_changeset(user, %{password: new})

        case Emisar.Repo.update(changeset) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Password updated.")
             |> assign_password_form()}

          {:error, _cs} ->
            {:noreply, put_flash(socket, :error, "Could not update password.")}
        end
    end
  end

  def handle_event("start_mfa", _params, socket) do
    secret = Auth.generate_mfa_secret()
    encoded = Base.encode32(secret, padding: false)

    issuer = "emisar"
    account_label = socket.assigns.current_user.email
    uri = "otpauth://totp/#{issuer}:#{account_label}?secret=#{encoded}&issuer=#{issuer}"

    {:noreply,
     socket
     |> assign(:mfa_secret, secret)
     |> assign(:mfa_uri, uri)
     |> assign_mfa_form()}
  end

  def handle_event("cancel_mfa", _params, socket) do
    {:noreply,
     socket
     |> assign(:mfa_secret, nil)
     |> assign(:mfa_uri, nil)
     |> assign_mfa_form()}
  end

  def handle_event("confirm_mfa", %{"mfa" => %{"otp" => otp}}, socket) do
    user = socket.assigns.current_user
    secret = socket.assigns.mfa_secret

    cond do
      is_nil(secret) ->
        {:noreply, put_flash(socket, :error, "Start the enable flow first.")}

      true ->
        case Auth.enable_mfa(user, secret, otp) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "MFA enabled.")
             |> assign(:current_user, updated)
             |> assign(:mfa_enabled?, true)
             |> assign(:mfa_secret, nil)
             |> assign(:mfa_uri, nil)}

          {:error, :invalid_otp} ->
            {:noreply, put_flash(socket, :error, "Invalid code — try the next one.")}

          {:error, _cs} ->
            {:noreply, put_flash(socket, :error, "Could not enable MFA.")}
        end
    end
  end

  def handle_event("disable_mfa", _params, socket) do
    case Auth.disable_mfa(socket.assigns.current_user) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "MFA disabled.")
         |> assign(:current_user, updated)
         |> assign(:mfa_enabled?, false)}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Could not disable MFA.")}
    end
  end

  defp mfa_enabled?(%{mfa_enabled_at: nil}), do: false
  defp mfa_enabled?(%{mfa_enabled_at: %DateTime{}}), do: true
  defp mfa_enabled?(_), do: false

  defp assign_profile_form(socket, user) do
    assign(socket, :profile_form, to_form(%{"full_name" => user.full_name || ""}, as: "profile"))
  end

  defp assign_password_form(socket) do
    params = %{"current_password" => "", "password" => "", "password_confirmation" => ""}
    assign(socket, :password_form, to_form(params, as: "password"))
  end

  defp assign_mfa_form(socket) do
    assign(socket, :mfa_form, to_form(%{"otp" => ""}, as: "mfa"))
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={nil}
    >
      <:title>Profile</:title>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <.card>
          <.section_header title="Profile" />
          <p class="mt-1 text-xs text-zinc-500">
            Update your display name. Email changes go through a separate verification.
          </p>

          <.simple_form for={@profile_form} id="profile_form" phx-change="validate_profile" phx-submit="save_profile">
            <.input
              type="text"
              name="profile[email]"
              value={@current_user.email}
              label="Email"
              disabled
            />
            <.input
              field={@profile_form[:full_name]}
              type="text"
              label="Full name"
              placeholder="Ada Lovelace"
            />

            <:actions>
              <.button phx-disable-with="Saving...">Save profile</.button>
            </:actions>
          </.simple_form>
        </.card>

        <.card>
          <.section_header title="Password" />
          <p class="mt-1 text-xs text-zinc-500">
            You'll stay signed in on this device. Other sessions are unaffected. Use at least 12 characters.
          </p>

          <.simple_form for={@password_form} id="password_form" phx-submit="change_password">
            <.input
              field={@password_form[:current_password]}
              type="password"
              label="Current password"
              autocomplete="current-password"
              required
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              minlength="12"
              required
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              minlength="12"
              required
            />

            <:actions>
              <.button phx-disable-with="Updating...">Change password</.button>
            </:actions>
          </.simple_form>
        </.card>

        <.card class="lg:col-span-2">
          <.section_header title="Two-factor authentication">
            <.status_badge status={if @mfa_enabled?, do: "success", else: "pending"} />
          </.section_header>
          <p class="mt-1 text-xs text-zinc-500">
            Adds a TOTP code requirement at sign in (Google Authenticator, 1Password, etc).
          </p>

          <%= cond do %>
            <% @mfa_enabled? -> %>
              <div class="mt-6">
                <button
                  phx-click="disable_mfa"
                  data-confirm="Disable MFA on your account?"
                  class="rounded-lg border border-rose-500/40 px-3 py-1.5 text-sm font-medium text-rose-200 hover:bg-rose-500/10"
                >
                  Disable MFA
                </button>
              </div>

            <% @mfa_uri -> %>
              <div class="mt-6 space-y-4">
                <p class="text-sm text-zinc-300">
                  Add this URI to your authenticator app, then enter the 6-digit code below to confirm.
                </p>

                <div class="flex items-center gap-2 rounded-lg bg-zinc-950/80 p-3 ring-1 ring-zinc-800">
                  <code class="flex-1 break-all font-mono text-xs text-zinc-200">{@mfa_uri}</code>
                  <button
                    type="button"
                    class="rounded bg-indigo-500/20 px-2 py-1 text-xs font-semibold text-indigo-100 hover:bg-indigo-500/30"
                    onclick={"navigator.clipboard.writeText('#{@mfa_uri}')"}
                  >
                    Copy
                  </button>
                </div>

                <.simple_form for={@mfa_form} id="mfa_form" phx-submit="confirm_mfa">
                  <.input
                    field={@mfa_form[:otp]}
                    type="text"
                    label="6-digit code"
                    placeholder="123 456"
                    autocomplete="one-time-code"
                    inputmode="numeric"
                    required
                  />

                  <:actions>
                    <.button phx-disable-with="Verifying...">Confirm and enable</.button>
                    <button
                      type="button"
                      phx-click="cancel_mfa"
                      class="text-sm font-medium text-zinc-400 hover:text-zinc-200"
                    >
                      Cancel
                    </button>
                  </:actions>
                </.simple_form>
              </div>

            <% true -> %>
              <div class="mt-6">
                <button
                  phx-click="start_mfa"
                  class="rounded-lg bg-indigo-500 px-3 py-1.5 text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
                >
                  Enable MFA
                </button>
              </div>
          <% end %>
        </.card>
      </div>
    </.dashboard_shell>
    """
  end
end
