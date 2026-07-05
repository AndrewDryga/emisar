defmodule EmisarWeb.ProfileLive do
  use EmisarWeb, :live_view
  alias Emisar.{Auth, Users}
  alias EmisarWeb.UserAgent
  alias Phoenix.LiveView.JS

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
     |> assign_mfa_form()
     |> reset_email_step()
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
      case Auth.list_sessions_for_user(socket.assigns.current_subject, page: [limit: 100]) do
        {:ok, list, _meta} -> list
        _ -> []
      end

    current_digest = current_session_digest(socket.assigns.current_session_token)
    # Pin the current device to the top so it's the anchor an operator reads
    # from, not one row lost among the others.
    sorted = Enum.sort_by(sessions, &(not current_session?(&1, current_digest)))
    assign(socket, :sessions, sorted) |> assign(:current_session_digest, current_digest)
  end

  defp current_session_digest(nil), do: nil
  defp current_session_digest(token) when is_binary(token), do: Emisar.Crypto.hash(token)

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

  # Email is identity-defining — it controls every future magic link — so a
  # self-service change is credential-grade: the submit only STARTS a step-up
  # (an MFA-on user re-enters a TOTP code; everyone else confirms a one-time
  # code emailed to their CURRENT address) and the change commits only after
  # `confirm_email_change` verifies it. A stolen session alone — no second
  # factor, no inbox — can't pass it.
  def handle_event("save_email", %{"email" => params}, socket) do
    user = socket.assigns.current_user
    new_email = String.trim(params["email"] || "")
    changeset = Users.change_user(user, %{"email" => new_email})

    cond do
      not changeset.valid? ->
        changeset = Map.put(changeset, :action, :validate)
        {:noreply, assign(socket, :email_form, to_form(changeset, as: "email"))}

      not Map.has_key?(changeset.changes, :email) ->
        {:noreply, put_flash(socket, :info, "That's already your email.")}

      true ->
        {:noreply, start_email_step_up(socket, user, new_email)}
    end
  end

  def handle_event("confirm_email_change", %{"email_step" => %{"code" => code}}, socket) do
    %{email_step: step, pending_new_email: new_email, current_subject: subject} = socket.assigns

    # Sequencing guard is the web's own state; the step-up factor decision, the
    # verify, and the commit are all `Auth.confirm_email_change`'s call — the
    # domain re-derives the factor from the fresh row and gates the write.
    if step in [:totp, :code] and is_binary(new_email) do
      handle_email_change_confirmation(socket, new_email, String.trim(code || ""), subject, step)
    else
      # Out-of-sequence (fired over the socket while :idle, before any save_email
      # started a step-up) — fail closed (IL-15: a handler is reachable over the
      # socket regardless of what's rendered).
      {:noreply, put_flash(socket, :error, "Start an email change first.")}
    end
  end

  def handle_event("resend_email_code", _params, socket) do
    user = socket.assigns.current_user
    Auth.issue_email_change_code(socket.assigns.pending_new_email, socket.assigns.current_subject)
    {:noreply, put_flash(socket, :info, "We sent a new code to #{user.email}.")}
  end

  def handle_event("cancel_email_change", _params, socket) do
    {:noreply,
     socket
     |> assign_email_form(socket.assigns.current_user)
     |> reset_email_step()}
  end

  def handle_event("revoke_session", %{"id" => id}, socket) do
    case Auth.revoke_session(id, socket.assigns.current_subject) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Session revoked.") |> load_sessions()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Session no longer exists.")}
    end
  end

  def handle_event("revoke_other_sessions", _params, socket) do
    keep = socket.assigns.current_session_token

    revoked_count =
      Auth.revoke_and_disconnect_other_sessions!(keep, socket.assigns.current_subject)

    msg =
      case revoked_count do
        0 -> "No other sessions to revoke."
        1 -> "1 other session signed out."
        revoked_count -> "#{revoked_count} other sessions signed out."
      end

    {:noreply, socket |> put_flash(:info, msg) |> load_sessions()}
  end

  def handle_event("start_mfa", _params, socket) do
    secret = Auth.generate_mfa_secret()
    uri = EmisarWeb.MfaQr.provisioning_uri(socket.assigns.current_user.email, secret)

    {:noreply,
     socket
     |> assign(:mfa_secret, secret)
     |> assign(:mfa_uri, uri)
     |> assign(:mfa_qr_svg, EmisarWeb.MfaQr.svg(uri))
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
    secret = socket.assigns.mfa_secret

    if is_nil(secret) do
      {:noreply, put_flash(socket, :error, "Start the enable flow first.")}
    else
      case Auth.enable_mfa(secret, otp, socket.assigns.current_subject) do
        {:ok, updated, recovery_codes} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "2FA enabled. Copy your recovery codes below — they'll only be shown once."
           )
           |> assign(:current_user, updated)
           |> assign(:mfa_enabled?, true)
           |> assign(:mfa_recovery_codes, recovery_codes)
           |> assign(:mfa_secret, nil)
           |> assign(:mfa_uri, nil)
           |> assign(:mfa_qr_svg, nil)}

        {:error, :invalid_otp} ->
          {:noreply, put_flash(socket, :error, "Invalid code — try the next one.")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not enable 2FA.")}
      end
    end
  end

  def handle_event("regenerate_recovery_codes", _params, socket) do
    case Auth.regenerate_mfa_recovery_codes(socket.assigns.current_subject) do
      {:ok, updated, codes} ->
        {:noreply,
         socket
         |> put_flash(:info, "New recovery codes generated. Old codes are now invalid.")
         |> assign(:current_user, updated)
         |> assign(:mfa_recovery_codes, codes)}

      {:error, :mfa_not_enabled} ->
        {:noreply, put_flash(socket, :error, "Enable 2FA first.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not generate recovery codes.")}
    end
  end

  def handle_event("dismiss_recovery_codes", _params, socket) do
    {:noreply, assign(socket, :mfa_recovery_codes, nil)}
  end

  def handle_event("disable_mfa", _params, socket) do
    case Auth.disable_mfa(socket.assigns.current_subject) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "2FA disabled.")
         |> assign(:current_user, updated)
         |> assign(:mfa_enabled?, false)
         |> assign(:mfa_recovery_codes, nil)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not disable 2FA.")}
    end
  end

  defp mfa_enabled?(%{mfa_enabled_at: nil}), do: false
  defp mfa_enabled?(%{mfa_enabled_at: %DateTime{}}), do: true
  defp mfa_enabled?(_), do: false

  # Unused recovery-code digests left on the user (consumed ones are removed);
  # `current_user` is kept fresh after enable/regenerate, so the count is too.
  defp recovery_codes_remaining(%{mfa_recovery_codes: codes}) when is_list(codes),
    do: length(codes)

  defp recovery_codes_remaining(_), do: 0

  # Server-side QR rendering — keeps it dependency-free at the JS level
  # and avoids leaking the otpauth URI through a third-party image
  # service. The SVG inlines into the page; authenticator apps scan it
  # directly from the screen.
  # Renders an SVG with explicit width AND viewBox so it scales cleanly
  # regardless of the surrounding flex/grid container. EQRCode's
  defp assign_profile_form(socket, user) do
    changeset = Users.change_user(user, %{"full_name" => user.full_name || ""})
    assign(socket, :profile_form, to_form(changeset, as: "profile"))
  end

  defp assign_email_form(socket, user) do
    changeset = Users.change_user(user, %{"email" => user.email || ""})
    assign(socket, :email_form, to_form(changeset, as: "email"))
  end

  # Email-change step-up state: :idle (the edit form), :totp (an MFA-on user
  # re-enters an authenticator code), or :code (a one-time code emailed to the
  # current address). `pending_new_email` is the change awaiting confirmation.
  defp reset_email_step(socket) do
    socket
    |> assign(:email_step, :idle)
    |> assign(:pending_new_email, nil)
    |> assign(:email_step_form, to_form(%{"code" => ""}, as: "email_step"))
  end

  defp handle_email_change_confirmation(socket, new_email, code, subject, step) do
    case Auth.confirm_email_change(new_email, code, subject) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Email updated.")
         |> assign(:current_user, updated)
         |> assign_email_form(updated)
         |> reset_email_step()}

      {:error, :replay} ->
        {:noreply,
         put_flash(socket, :error, "That code was just used — wait a moment for the next one.")}

      {:error, :invalid} ->
        {:noreply, put_flash(socket, :error, step_up_error(step))}

      # Step-up passed but the email itself was rejected (e.g. now taken) — the
      # one-time proof is spent, so send them back to the start.
      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not change to that email — it may already be in use.")
         |> reset_email_step()}
    end
  end

  # The DOMAIN decides the factor from the user's CURRENT row (`begin_email_change`
  # re-reads it) — not `mfa_enabled?`, which is a stale mount snapshot that could
  # downgrade the challenge — and issues the emailed code on the `:code` path.
  defp start_email_step_up(socket, user, new_email) do
    socket = assign(socket, :pending_new_email, new_email)

    case Auth.begin_email_change(new_email, socket.assigns.current_subject) do
      {:ok, :totp} ->
        assign(socket, :email_step, :totp)

      {:ok, :code} ->
        socket
        |> assign(:email_step, :code)
        |> put_flash(:info, "We emailed a confirmation code to #{user.email}.")
    end
  end

  defp step_up_error(:totp), do: "That authenticator code didn't match. Try again."

  defp step_up_error(_),
    do: "That confirmation code is wrong or expired. Try again, or resend a new one."

  defp assign_mfa_form(socket) do
    assign(socket, :mfa_form, to_form(%{"otp" => ""}, as: "mfa"))
  end

  defp current_session?(%{token: digest}, current_digest) when not is_nil(current_digest),
    do: digest == current_digest

  defp current_session?(_, _), do: false

  defp session_ip(%{metadata: %{"ip_address" => ip}}) when is_binary(ip) and ip != "", do: ip
  defp session_ip(_), do: nil

  defp session_device_label(%{metadata: %{"user_agent" => ua}}) when is_binary(ua),
    do: UserAgent.label(ua)

  defp session_device_label(_), do: "Unknown device"

  # No-op for the broadcasts the on_mount badge/fleet hooks forward (approvals,
  # pack trust, runner presence). The hooks own those nav cues; this page ignores them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:profile}
      width={:settings}
    >
      <:title>Profile</:title>

      <.page_intro>
        Your identity and sign-in security — the same across every workspace you belong to.
        <.doc_link href="/security">Security overview</.doc_link>
      </.page_intro>

      <%!-- CONTENT ON CANVAS: one naked section per concern (§8.1 — the
           fields, the enrollment block, and the reveal card are the only
           surfaces; a panel around a form was an island). --%>
      <div class="mt-4 max-w-2xl space-y-12">
        <section>
          <.section_header title="Display name">
            <:subtitle>How you appear to other members.</:subtitle>
          </.section_header>
          <.simple_form
            for={@profile_form}
            id="profile_form"
            phx-change="validate_profile"
            phx-submit="save_profile"
          >
            <%!-- No field label — the section title already says "Display name"
                 (one voice on a single-field section); aria-label keeps the
                 accessible name. --%>
            <.input
              field={@profile_form[:full_name]}
              type="text"
              aria-label="Display name"
              placeholder="Ada Lovelace"
            />
            <:actions>
              <.button variant={:secondary} phx-disable-with="Saving...">Save</.button>
            </:actions>
          </.simple_form>
        </section>

        <section>
          <.section_header title="Email">
            <:subtitle>
              Used to sign in — every future sign-in link goes to it, so a change is
              confirmed with a second step.
            </:subtitle>
          </.section_header>
          <%= case @email_step do %>
            <% :idle -> %>
              <.simple_form
                for={@email_form}
                id="email_form"
                phx-change="validate_email"
                phx-submit="save_email"
              >
                <%!-- No field label — the panel title "Email" carries it (one
                     voice on a single-field panel); aria-label for a11y. --%>
                <.input
                  field={@email_form[:email]}
                  type="email"
                  aria-label="Email address"
                  autocomplete="email"
                  required
                />
                <:actions>
                  <.button variant={:secondary} phx-disable-with="Checking...">Update email</.button>
                </:actions>
              </.simple_form>
            <% step -> %>
              <.simple_form
                for={@email_step_form}
                id="email_step_form"
                phx-submit="confirm_email_change"
              >
                <p class="text-sm text-zinc-300">
                  Confirm changing your email to <span class="font-medium text-zinc-100">{@pending_new_email}</span>.
                </p>
                <p :if={step == :code} class="text-xs text-zinc-400">
                  We emailed a 6-digit code to your current address ({@current_user.email}). Entering
                  it proves it's really you — an open session alone can't change your email.
                </p>
                <p :if={step == :totp} class="text-xs text-zinc-400">
                  Enter the code from your authenticator app — your second factor confirms the change.
                </p>
                <.code_input
                  id="email-step-code"
                  name="email_step[code]"
                  numeric
                  label={if step == :totp, do: "Authenticator code", else: "Confirmation code"}
                />
                <:actions>
                  <.button phx-disable-with="Confirming...">Confirm change</.button>
                  <.button
                    :if={step == :code}
                    variant={:secondary}
                    size={:md}
                    type="button"
                    phx-click="resend_email_code"
                  >
                    Resend code
                  </.button>
                  <.button
                    variant={:secondary}
                    size={:md}
                    type="button"
                    phx-click="cancel_email_change"
                  >
                    Cancel
                  </.button>
                </:actions>
              </.simple_form>
          <% end %>
        </section>

        <section>
          <.section_header title="Two-factor authentication">
            <:subtitle>
              Adds a TOTP code at sign-in, so a leaked sign-in link alone can't get in.
            </:subtitle>
            <:actions>
              <.chip :if={@mfa_enabled?} tone={:brand}>On</.chip>
              <span :if={not @mfa_enabled?} class="flex items-center gap-1.5 text-xs">
                <.status_dot tone={:neutral} size={:sm} />
                <span class="text-zinc-500">off</span>
              </span>
            </:actions>
          </.section_header>

          <%= cond do %>
            <% @mfa_recovery_codes -> %>
              <%!-- One-shot reveal — codes are only shown right after
                   enable / regenerate. The card forces an explicit
                   "I saved them" before the user can close. --%>
              <.secret_reveal
                id="mfa-recovery-codes"
                variant={:card}
                title="Save your recovery codes"
                codes={@mfa_recovery_codes}
                download_name="emisar-recovery-codes.txt"
              >
                Each code works once if you can't reach your authenticator. Store them in a
                password manager — we can't show them again.
                <:actions>
                  <.confirm_button
                    id="ack-recovery-codes"
                    title="Stored them somewhere safe?"
                    confirm_label="I've saved them"
                    variant={:secondary}
                    tone={:neutral}
                    size={:sm}
                    on_confirm={JS.push("dismiss_recovery_codes")}
                  >
                    <:body>Once this closes we can't show these recovery codes again.</:body>
                    I've saved them
                  </.confirm_button>
                </:actions>
              </.secret_reveal>
            <% @mfa_enabled? -> %>
              <p class="text-sm text-zinc-300">
                You're protected by a second factor. Disabling means a leaked sign-in link is
                enough to sign in.
              </p>
              <%!-- Recovery codes burn down one per lost-device sign-in, but the
                   count was never surfaced — nudge to regenerate before they run
                   out and a lost authenticator becomes a lockout. --%>
              <% remaining = recovery_codes_remaining(@current_user) %>
              <p class={[
                "mt-3 text-xs",
                if(remaining <= 2, do: "font-medium text-amber-300", else: "text-zinc-500")
              ]}>
                {remaining} recovery {if remaining == 1, do: "code", else: "codes"} remaining.<span :if={
                  remaining <= 2
                }>
                  Regenerate for a fresh set before a lost authenticator locks you out.</span>
              </p>
              <div class="mt-4 flex flex-wrap items-center gap-3">
                <.confirm_button
                  id="regen-codes"
                  title="Generate a new set of recovery codes?"
                  confirm_label="Regenerate codes"
                  variant={:secondary}
                  tone={:neutral}
                  size={:md}
                  on_confirm={JS.push("regenerate_recovery_codes")}
                >
                  <:body>Old codes will stop working.</:body>
                  Regenerate recovery codes
                </.confirm_button>
                <.confirm_button
                  id="disable-2fa"
                  title="Disable 2FA on your account?"
                  confirm_label="Disable 2FA"
                  variant={:secondary}
                  tone={:rose}
                  size={:md}
                  on_confirm={JS.push("disable_mfa")}
                >
                  <:body>A leaked sign-in link alone will then be enough to sign in.</:body>
                  Disable 2FA
                </.confirm_button>
              </div>
            <% @mfa_uri -> %>
              <.mfa_enrollment qr_svg={@mfa_qr_svg} uri={@mfa_uri} form={@mfa_form} variant={:split}>
                <:instructions>
                  Scan with Google Authenticator, 1Password, Authy, or similar — then enter
                  the 6-digit code to confirm.
                </:instructions>
                <:actions>
                  <.button phx-disable-with="Verifying...">Confirm and enable</.button>
                  <.button variant={:ghost} type="button" phx-click="cancel_mfa">
                    Cancel
                  </.button>
                </:actions>
              </.mfa_enrollment>
            <% true -> %>
              <p class="text-sm text-zinc-300">
                Generate a TOTP secret, scan it with your authenticator app, then confirm with a
                6-digit code to turn it on.
              </p>
              <%!-- Secondary like every profile island action — this page has
                   no single primary (ONE emerald fill per viewport). --%>
              <.button variant={:secondary} phx-click="start_mfa" size={:md} class="mt-4">
                Set up 2FA
              </.button>
          <% end %>
        </section>

        <section>
          <.section_header title="Active sessions">
            <:subtitle>
              Each row is one signed-in browser or device. Sign out of any you don't
              recognize — your current device stays signed in.
            </:subtitle>
            <:actions>
              <.confirm_button
                :if={length(@sessions) > 1}
                id="signout-others"
                title="Sign out of every other browser and device?"
                confirm_label="Sign out everywhere else"
                variant={:secondary}
                tone={:rose}
                size={:sm}
                on_confirm={JS.push("revoke_other_sessions")}
              >
                <:body>Your current device stays signed in.</:body>
                Sign out everywhere else
              </.confirm_button>
            </:actions>
          </.section_header>

          <%!-- No max-height: the scroll cap cropped the next row to a ~10px
               sliver that read as a rendering bug; "Sign out everywhere else"
               is the long-list affordance. --%>
          <ul class="divide-y divide-zinc-800/70 text-sm">
            <.list_row
              :for={session <- @sessions}
              icon={session_device_icon(session)}
              class={current_session?(session, @current_session_digest) && "bg-brand-500/[0.04]"}
            >
              <:title>
                <span class="truncate font-medium text-zinc-100">
                  {session_device_label(session)}
                </span>
              </:title>
              <:chips>
                <.chip :if={current_session?(session, @current_session_digest)} tone={:neutral}>
                  this device
                </.chip>
              </:chips>
              <:meta>
                Started <.local_time value={session.inserted_at} mode={:relative} />
                <%= if session_ip(session) do %>
                  · <span class="font-mono">{session_ip(session)}</span>
                <% end %>
              </:meta>
              <:actions>
                <%!-- Neutral, not rose — a routine self-service sign-out shouldn't
                     read as dangerous as the account-wide "Sign out everywhere else"
                     (which keeps the danger tone). --%>
                <.confirm_button
                  :if={not current_session?(session, @current_session_digest)}
                  id={"signout-session-#{session.id}"}
                  title="Sign out this session?"
                  confirm_label="Sign out"
                  variant={:ghost}
                  tone={:neutral}
                  size={:sm}
                  class="shrink-0"
                  on_confirm={JS.push("revoke_session", value: %{id: session.id})}
                >
                  <:body>That browser or device will need to sign in again.</:body>
                  Sign out
                </.confirm_button>
              </:actions>
            </.list_row>
            <li :if={@sessions == []} class="py-6 text-xs text-zinc-500">
              No active sessions.
            </li>
          </ul>
        </section>
      </div>
    </.dashboard_shell>
    """
  end

  # Picks an icon for the session row that hints at the device class —
  # makes the row visually scannable instead of "wall of identical text".
  defp session_device_icon(%{metadata: %{"user_agent" => ua}}), do: UserAgent.icon(ua)
  defp session_device_icon(_), do: "hero-globe-alt"
end
