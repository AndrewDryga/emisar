defmodule EmisarWeb.ProfileLive do
  use EmisarWeb, :live_view

  alias Emisar.{Auth, Users}

  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Profile")
     |> assign(:mfa_enabled?, mfa_enabled?(user))
     |> assign(:mfa_secret, nil)
     |> assign(:mfa_uri, nil)
     |> assign(:mfa_qr_svg, nil)
     |> assign(:mfa_recovery_codes, nil)
     |> assign(:current_session_token, session["user_token"])
     |> assign_profile_form(user)
     |> assign_email_form(user)
     |> assign_password_form()
     |> assign_mfa_form()
     |> maybe_load_sessions()}
  end

  # IL-18: the session list is the only DB read on this page — skip it on
  # the pre-connect render so `mount/3` does no query work; the connected
  # mount fills it in.
  defp maybe_load_sessions(socket) do
    if connected?(socket) do
      load_sessions(socket)
    else
      socket
      |> assign(:sessions, [])
      |> assign(:current_session_digest, nil)
    end
  end

  defp load_sessions(socket) do
    sessions =
      case Auth.list_sessions_for_user(socket.assigns.current_user, page: [limit: 100]) do
        {:ok, list, _meta} -> list
        _ -> []
      end

    current_digest = current_session_digest(socket.assigns.current_session_token)
    assign(socket, :sessions, sessions) |> assign(:current_session_digest, current_digest)
  end

  defp current_session_digest(nil), do: nil
  defp current_session_digest(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  def handle_event("validate_profile", %{"profile" => params}, socket) do
    changeset =
      socket.assigns.current_user
      |> Users.change_user(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :profile_form, to_form(changeset, as: "profile"))}
  end

  def handle_event("save_profile", %{"profile" => params}, socket) do
    case Users.update_user_profile(params, socket.assigns.current_subject) do
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

  def handle_event("validate_email", %{"email" => params}, socket) do
    changeset =
      socket.assigns.current_user
      |> Users.change_user(%{"email" => params["email"] || ""})
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :email_form, to_form(changeset, as: "email"))}
  end

  def handle_event("save_email", %{"email" => params}, socket) do
    new_email = String.trim(params["email"] || "")
    current = params["current_password"] || ""

    case Users.update_user_email(new_email, current, socket.assigns.current_subject) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Email updated.")
         |> assign(:current_user, updated)
         |> assign_email_form(updated)}

      {:error, :invalid_current_password} ->
        {:noreply, put_flash(socket, :error, "Current password is incorrect.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :email_form, to_form(cs, as: "email"))}
    end
  end

  def handle_event("validate_password", %{"password" => params}, socket) do
    changeset =
      socket.assigns.current_user
      |> Users.change_password(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :password_form, to_form(changeset, as: "password"))}
  end

  def handle_event("change_password", %{"password" => params}, socket) do
    user = socket.assigns.current_user
    subject = socket.assigns.current_subject
    current_token = socket.assigns.current_session_token

    current = params["current_password"] || ""
    new = params["password"] || ""

    # Length + confirmation-mismatch are field errors on the password form —
    # render them inline (border + message) instead of a flash. The
    # current-password challenge isn't a field of the password schema; a
    # wrong one stays a concise flash.
    changeset = Users.change_password(user, params)

    if changeset.valid? do
      case Users.change_user_password(current, new, subject) do
        {:ok, _updated} ->
          # A successful password change blows the old credential — log out
          # every other device immediately, both at the DB layer (cookie no
          # longer resolves) and over PubSub (open LV tabs hard-disconnect).
          if is_binary(current_token) do
            _ = Auth.revoke_and_disconnect_other_sessions!(current_token, subject)
          end

          {:noreply,
           socket
           |> put_flash(:info, "Password updated. Other devices were signed out.")
           |> assign_password_form()
           |> load_sessions()}

        {:error, :invalid_current_password} ->
          {:noreply, put_flash(socket, :error, "Current password is incorrect.")}

        {:error, _cs} ->
          {:noreply, put_flash(socket, :error, "Could not update password.")}
      end
    else
      changeset = Map.put(changeset, :action, :validate)
      {:noreply, assign(socket, :password_form, to_form(changeset, as: "password"))}
    end
  end

  def handle_event("revoke_session", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Auth.revoke_session(user, id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Session revoked.") |> load_sessions()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Session no longer exists.")}
    end
  end

  def handle_event("revoke_other_sessions", _params, socket) do
    keep = socket.assigns.current_session_token
    n = Auth.revoke_and_disconnect_other_sessions!(keep, socket.assigns.current_subject)

    msg =
      case n do
        0 -> "No other sessions to revoke."
        1 -> "1 other session signed out."
        n -> "#{n} other sessions signed out."
      end

    {:noreply, socket |> put_flash(:info, msg) |> load_sessions()}
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
     |> assign(:mfa_qr_svg, mfa_qr_svg(uri))
     |> assign_mfa_form()}
  end

  def handle_event("cancel_mfa", _params, socket) do
    {:noreply,
     socket
     |> assign(:mfa_secret, nil)
     |> assign(:mfa_uri, nil)
     |> assign(:mfa_qr_svg, nil)
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
          {:ok, updated, recovery_codes} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "MFA enabled. Copy your recovery codes below — they'll only be shown once."
             )
             |> assign(:current_user, updated)
             |> assign(:mfa_enabled?, true)
             |> assign(:mfa_recovery_codes, recovery_codes)
             |> assign(:mfa_secret, nil)
             |> assign(:mfa_uri, nil)
             |> assign(:mfa_qr_svg, nil)}

          {:error, :invalid_otp} ->
            {:noreply, put_flash(socket, :error, "Invalid code — try the next one.")}

          {:error, _cs} ->
            {:noreply, put_flash(socket, :error, "Could not enable MFA.")}
        end
    end
  end

  def handle_event("regenerate_recovery_codes", _params, socket) do
    case Auth.regenerate_mfa_recovery_codes(socket.assigns.current_user) do
      {:ok, updated, codes} ->
        {:noreply,
         socket
         |> put_flash(:info, "New recovery codes generated. Old codes are now invalid.")
         |> assign(:current_user, updated)
         |> assign(:mfa_recovery_codes, codes)}

      {:error, :mfa_not_enabled} ->
        {:noreply, put_flash(socket, :error, "Enable MFA first.")}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Could not generate recovery codes.")}
    end
  end

  def handle_event("dismiss_recovery_codes", _params, socket) do
    {:noreply, assign(socket, :mfa_recovery_codes, nil)}
  end

  def handle_event("disable_mfa", _params, socket) do
    case Auth.disable_mfa(socket.assigns.current_user) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "MFA disabled.")
         |> assign(:current_user, updated)
         |> assign(:mfa_enabled?, false)
         |> assign(:mfa_recovery_codes, nil)}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Could not disable MFA.")}
    end
  end

  defp mfa_enabled?(%{mfa_enabled_at: nil}), do: false
  defp mfa_enabled?(%{mfa_enabled_at: %DateTime{}}), do: true
  defp mfa_enabled?(_), do: false

  # Server-side QR rendering — keeps it dependency-free at the JS level
  # and avoids leaking the otpauth URI through a third-party image
  # service. The SVG inlines into the page; authenticator apps scan it
  # directly from the screen.
  # Renders an SVG with explicit width AND viewBox so it scales cleanly
  # regardless of the surrounding flex/grid container. EQRCode's
  # `viewbox: true` (singular w/o explicit width) emits a viewBox-only
  # SVG whose intrinsic size collapses to 0 in some browsers — render
  # both attributes so it works everywhere. 240px = comfortable scan
  # distance on a phone camera held a foot from the screen.
  defp mfa_qr_svg(uri) do
    uri
    |> EQRCode.encode()
    |> EQRCode.svg(width: 240, background_color: "#ffffff", color: "#000000")
  end

  defp assign_profile_form(socket, user) do
    changeset = Users.change_user(user, %{"full_name" => user.full_name || ""})
    assign(socket, :profile_form, to_form(changeset, as: "profile"))
  end

  defp assign_email_form(socket, user) do
    changeset = Users.change_user(user, %{"email" => user.email || ""})
    assign(socket, :email_form, to_form(changeset, as: "email"))
  end

  defp assign_password_form(socket) do
    changeset = Users.change_password(socket.assigns.current_user)
    assign(socket, :password_form, to_form(changeset, as: "password"))
  end

  defp assign_mfa_form(socket) do
    assign(socket, :mfa_form, to_form(%{"otp" => ""}, as: "mfa"))
  end

  defp current_session?(%{token: digest}, current_digest) when not is_nil(current_digest),
    do: digest == current_digest

  defp current_session?(_, _), do: false

  defp session_ip(%{metadata: %{"ip_address" => ip}}) when is_binary(ip) and ip != "", do: ip
  defp session_ip(_), do: nil

  # Best-effort device label from the User-Agent string. Recognizes the
  # common browser/OS combos a human session will produce; falls back
  # to the raw UA token or "Unknown device" when nothing parses.
  defp session_device_label(%{metadata: %{"user_agent" => ua}}) when is_binary(ua),
    do: classify_ua(ua)

  defp session_device_label(_), do: "Unknown device"

  defp classify_ua(ua) do
    browser =
      cond do
        ua =~ ~r/Edg\//i -> "Edge"
        ua =~ ~r/Chrome\//i -> "Chrome"
        ua =~ ~r/Firefox\//i -> "Firefox"
        ua =~ ~r/Safari\//i and not (ua =~ ~r/Chrome\//i) -> "Safari"
        true -> nil
      end

    os =
      cond do
        ua =~ ~r/Mac OS X/i -> "Mac"
        ua =~ ~r/Windows/i -> "Windows"
        ua =~ ~r/iPhone|iPad|iOS/i -> "iOS"
        ua =~ ~r/Android/i -> "Android"
        ua =~ ~r/Linux/i -> "Linux"
        true -> nil
      end

    case {browser, os} do
      {nil, nil} -> short_ua(ua)
      {b, nil} -> b
      {nil, o} -> o
      {b, o} -> "#{b} on #{o}"
    end
  end

  defp short_ua(ua) do
    case Regex.run(~r{^([^\s]+)}, ua) do
      [_, token] -> token
      _ -> "Unknown device"
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:profile}
    >
      <:title>Profile</:title>

      <%!-- Settings page pattern: max-width content, section per
           concern, label/description on the left, form on the right.
           No boxed cards — quieter visual rhythm than a 2-up grid. --%>
      <div class="mx-auto max-w-4xl divide-y divide-zinc-900">
        <.settings_section title="Display name" hint="How you appear to your teammates.">
          <.simple_form
            for={@profile_form}
            id="profile_form"
            phx-change="validate_profile"
            phx-submit="save_profile"
          >
            <.input
              field={@profile_form[:full_name]}
              type="text"
              label="Full name"
              placeholder="Ada Lovelace"
            />
            <:actions>
              <.button phx-disable-with="Saving...">Save</.button>
            </:actions>
          </.simple_form>
        </.settings_section>

        <.settings_section
          title="Email"
          hint="Used to sign in. Requires your current password to change."
        >
          <.simple_form
            for={@email_form}
            id="email_form"
            phx-change="validate_email"
            phx-submit="save_email"
          >
            <.input
              field={@email_form[:email]}
              type="email"
              label="Email address"
              autocomplete="email"
              required
            />
            <.input
              field={@email_form[:current_password]}
              type="password"
              label="Current password"
              autocomplete="current-password"
              required
            />
            <:actions>
              <.button phx-disable-with="Updating...">Update email</.button>
            </:actions>
          </.simple_form>
        </.settings_section>

        <.settings_section
          title="Password"
          hint="Use 12+ characters. Other sessions stay signed in — sign them out below if you suspect a leak."
        >
          <.simple_form
            for={@password_form}
            id="password_form"
            phx-change="validate_password"
            phx-submit="change_password"
          >
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
        </.settings_section>

        <.settings_section
          title="Two-factor authentication"
          hint="Adds a TOTP code requirement at sign-in. Strongly recommended."
        >
          <:meta>
            <span
              :if={@mfa_enabled?}
              class="inline-flex items-center gap-1.5 rounded-full bg-emerald-500/10 px-2 py-0.5 text-xs font-medium text-emerald-300 ring-1 ring-emerald-500/30"
            >
              <span class="h-1.5 w-1.5 rounded-full bg-emerald-400"></span>On
            </span>
            <span
              :if={not @mfa_enabled?}
              class="inline-flex items-center gap-1.5 rounded-full bg-zinc-500/10 px-2 py-0.5 text-xs font-medium text-zinc-400 ring-1 ring-zinc-700/40"
            >
              Off
            </span>
          </:meta>

          <%= cond do %>
            <% @mfa_recovery_codes -> %>
              <%!-- One-shot reveal — codes are only shown right after
                   enable / regenerate. The card forces an explicit
                   "I saved them" before the user can close. --%>
              <div class="rounded-xl border border-amber-500/40 bg-amber-500/[0.06] p-4">
                <h3 class="text-sm font-semibold text-amber-100">Save your recovery codes</h3>
                <p class="mt-1 text-xs text-amber-200/90">
                  Each code works once if you can't reach your authenticator. Store them in a
                  password manager — we can't show them again.
                </p>

                <%!-- Single-column list of full-width, monospace, high-
                     contrast cells. Each cell is itself a copy-to-
                     clipboard button so a user can grab one code without
                     selecting text. The hidden <code id> below holds the
                     newline-joined block for the "Copy all" button. --%>
                <ul class="mt-3 space-y-1.5">
                  <li :for={code <- @mfa_recovery_codes}>
                    <button
                      type="button"
                      id={"mfa-code-#{code}"}
                      phx-hook="CopyToClipboard"
                      data-clipboard-text={code}
                      data-clipboard-copied="Copied!"
                      data-clipboard-restore={code}
                      class="block w-full select-all rounded-md border border-amber-500/40 bg-black/60 px-3 py-2 text-left font-mono text-sm tracking-wide text-amber-50 hover:border-amber-400 hover:bg-black/80"
                      title="Click to copy this code"
                    >
                      {code}
                    </button>
                  </li>
                </ul>

                <code
                  id="mfa-recovery-codes-blob"
                  class="hidden"
                >
                  {Enum.join(@mfa_recovery_codes, "\n")}
                </code>

                <div class="mt-4 flex flex-wrap items-center gap-3">
                  <button
                    type="button"
                    id="copy-recovery-codes"
                    phx-hook="CopyToClipboard"
                    data-clipboard-target="#mfa-recovery-codes-blob"
                    data-clipboard-copied="Copied!"
                    data-clipboard-restore="Copy all"
                    class="rounded-lg bg-amber-500 px-3 py-1.5 text-xs font-semibold text-amber-950 hover:bg-amber-400"
                  >
                    Copy all
                  </button>
                  <button
                    type="button"
                    phx-click="dismiss_recovery_codes"
                    data-confirm="Got them stored somewhere safe?"
                    class="rounded-lg border border-zinc-700 px-3 py-1.5 text-xs font-medium text-zinc-300 hover:bg-zinc-900"
                  >
                    I've saved them
                  </button>
                </div>
              </div>
            <% @mfa_enabled? -> %>
              <p class="text-sm text-zinc-300">
                You're protected by a second factor. Disabling means a stolen password is enough
                to sign in.
              </p>
              <div class="mt-4 flex flex-wrap items-center gap-3">
                <button
                  phx-click="regenerate_recovery_codes"
                  data-confirm="Generate a new set of recovery codes? Old codes will stop working."
                  class="rounded-lg border border-zinc-700 px-3 py-1.5 text-sm font-medium text-zinc-200 hover:bg-zinc-900"
                >
                  Regenerate recovery codes
                </button>
                <button
                  phx-click="disable_mfa"
                  data-confirm="Disable MFA on your account?"
                  class="rounded-lg border border-rose-500/40 px-3 py-1.5 text-sm font-medium text-rose-200 hover:bg-rose-500/10"
                >
                  Disable MFA
                </button>
              </div>
            <% @mfa_uri -> %>
              <div class="grid grid-cols-1 gap-6 sm:grid-cols-[auto_1fr]">
                <div class="flex flex-col items-center gap-2">
                  <div class="rounded-lg bg-white p-3 [&>svg]:block [&>svg]:h-60 [&>svg]:w-60">
                    {raw(@mfa_qr_svg)}
                  </div>
                  <p class="text-[11px] text-zinc-500">Scan with your authenticator</p>
                </div>
                <div class="space-y-3">
                  <p class="text-sm text-zinc-300">
                    Scan with Google Authenticator, 1Password, Authy, or similar — then enter
                    the 6-digit code to confirm.
                  </p>
                  <details class="rounded-lg border border-zinc-800 bg-zinc-950/40">
                    <summary class="cursor-pointer px-3 py-2 text-xs font-medium text-zinc-400 hover:text-zinc-200">
                      Can't scan? Use a setup URI
                    </summary>
                    <div class="flex items-center gap-2 border-t border-zinc-800 p-3">
                      <code
                        id="mfa-uri"
                        class="flex-1 break-all font-mono text-[11px] text-zinc-200"
                      >
                        {@mfa_uri}
                      </code>
                      <.copy_button
                        target="#mfa-uri"
                        class="bg-indigo-500/20 px-2 text-indigo-100 hover:bg-indigo-500/30 font-semibold"
                      >
                        Copy
                      </.copy_button>
                    </div>
                  </details>
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
              </div>
            <% true -> %>
              <p class="text-sm text-zinc-300">
                Generate a TOTP secret, scan it with your authenticator app, then confirm with a
                6-digit code to turn it on.
              </p>
              <button
                phx-click="start_mfa"
                class="mt-4 rounded-lg bg-indigo-500 px-3 py-1.5 text-sm font-semibold text-zinc-950 hover:bg-indigo-400"
              >
                Set up 2FA
              </button>
          <% end %>
        </.settings_section>

        <.settings_section
          title="Active sessions"
          hint="Each row is one signed-in browser or device. Revoke any you don't recognize — your current device stays signed in."
        >
          <:meta>
            <button
              :if={length(@sessions) > 1}
              phx-click="revoke_other_sessions"
              data-confirm="Sign out of every other browser and device?"
              class="rounded-lg border border-rose-500/40 px-3 py-1.5 text-xs font-medium text-rose-200 hover:bg-rose-500/10"
            >
              Sign out everywhere else
            </button>
          </:meta>

          <ul class="divide-y divide-zinc-900 rounded-lg border border-zinc-900 bg-zinc-950/40 text-sm">
            <li
              :for={s <- @sessions}
              class="flex items-center justify-between gap-3 px-4 py-3"
            >
              <div class="flex min-w-0 items-center gap-3">
                <span class="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-zinc-900 text-zinc-400">
                  <.icon name={session_device_icon(s)} class="h-4 w-4" />
                </span>
                <div class="min-w-0">
                  <div class="flex items-center gap-2">
                    <span class="truncate font-medium text-zinc-100">
                      {session_device_label(s)}
                    </span>
                    <span
                      :if={current_session?(s, @current_session_digest)}
                      class="rounded bg-indigo-500/15 px-1.5 py-0.5 text-[10px] font-medium text-indigo-200 ring-1 ring-indigo-500/30"
                    >
                      This device
                    </span>
                  </div>
                  <div class="mt-0.5 truncate text-xs text-zinc-500">
                    Started {relative_time(s.inserted_at)}
                    <%= if session_ip(s) do %>
                      · <span class="font-mono">{session_ip(s)}</span>
                    <% end %>
                  </div>
                </div>
              </div>
              <button
                :if={not current_session?(s, @current_session_digest)}
                phx-click="revoke_session"
                phx-value-id={s.id}
                data-confirm="Sign out this session?"
                class="shrink-0 text-xs font-medium text-rose-300 hover:text-rose-200"
              >
                Revoke
              </button>
            </li>
            <li :if={@sessions == []} class="px-4 py-6 text-center text-xs text-zinc-500">
              No active sessions.
            </li>
          </ul>
        </.settings_section>
      </div>
    </.dashboard_shell>
    """
  end

  # Section wrapper: title + hint on the left, content on the right
  # (single-column on mobile, 1:2 split on sm+). Subtle top divider
  # comes from the parent's `divide-y`; first section's top is the
  # page top.
  attr :title, :string, required: true
  attr :hint, :string, default: nil
  slot :inner_block, required: true
  slot :meta

  defp settings_section(assigns) do
    ~H"""
    <section class="grid grid-cols-1 gap-6 py-10 sm:grid-cols-[minmax(0,1fr)_minmax(0,2fr)] sm:gap-12">
      <div>
        <div class="flex items-center justify-between gap-3">
          <h2 class="text-base font-semibold text-zinc-100">{@title}</h2>
          <div :for={m <- @meta}>{render_slot(m)}</div>
        </div>
        <p :if={@hint} class="mt-2 text-sm leading-relaxed text-zinc-500">{@hint}</p>
      </div>
      <div>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  # Picks an icon for the session row that hints at the device class —
  # makes the row visually scannable instead of "wall of identical text".
  defp session_device_icon(%{metadata: %{"user_agent" => ua}}) when is_binary(ua) do
    cond do
      ua =~ ~r/iPhone|iPad|Android/i -> "hero-device-phone-mobile"
      ua =~ ~r/Mozilla|WebKit/i -> "hero-computer-desktop"
      true -> "hero-globe-alt"
    end
  end

  defp session_device_icon(_), do: "hero-globe-alt"
end
