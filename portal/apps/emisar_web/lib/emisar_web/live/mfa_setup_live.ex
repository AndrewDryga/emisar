defmodule EmisarWeb.MfaSetupLive do
  @moduledoc """
  The workspace's MFA page at `/app/:slug/mfa_setup`. When a workspace requires
  MFA and this session has not proved the current factor,
  `UserAuth.on_mount(:ensure_account_compliant)` forwards every mount here. A
  Member without a factor enrolls; an enrolled Member verifies TOTP or a
  recovery code for this browser.

  Enrollment needs a fresh proof of the Member's own credential before a factor
  is added — session age never counts. A Member with a verified email proves its
  inbox with an emailed code (`Auth.mfa_facts/1` says `:email`); an SSO-only
  Member signs in again at its identity provider (`:sso`, `POST
  /app/:slug/mfa_setup/sso`) and the callback hands this page a short-lived
  proof in the session, which lands straight on the authenticator step. Then: a
  TOTP code, the recovery codes once, and on to the workspace. Voluntary
  management (disable, regenerate codes) stays on the profile page, which sends
  an SSO-only Member here to finish a voluntary enrollment the same way.
  """
  use EmisarWeb, :live_view
  alias Emisar.Auth
  alias EmisarWeb.{MfaEnrollment, MfaErrors, UserAuth}

  @email_unavailable_error "Your email address isn't verified, so we can't send a code to it. Ask your workspace administrator for help, or contact support@emisar.dev."
  @email_suppressed_error "Emisar cannot deliver mail to your address. Contact support to restore email delivery before setting up MFA."
  @email_delivery_error "We could not deliver the verification code. Try again. If it keeps failing, contact support."

  def mount(_params, session, socket) do
    %{current_membership: membership, account_compliance: compliance} = socket.assigns
    enrolled? = not is_nil(membership.mfa_enabled_at)
    sso_proof = session["mfa_enrollment_proof"]

    # `:assign_account_compliance` already asked the shared domain policy (and
    # bounced a session `require_sso` refuses), so its verdict is the
    # enroll-or-verify decision. A compliant Member only belongs here to finish
    # an enrollment its identity provider just proved; otherwise there is
    # nothing to do, so don't strand them.
    cond do
      compliance == {:error, :mfa_required} and enrolled? ->
        mount_challenge(socket)

      compliance == {:error, :mfa_required} ->
        mount_enrollment(socket, sso_proof, ~p"/app/#{socket.assigns.current_account}")

      not enrolled? and is_binary(sso_proof) ->
        mount_enrollment(
          socket,
          sso_proof,
          ~p"/app/#{socket.assigns.current_account}/settings/profile"
        )

      true ->
        {:ok, push_navigate(socket, to: ~p"/app/#{socket.assigns.current_account}")}
    end
  end

  defp mount_challenge(socket) do
    {:ok,
     socket
     |> assign(:page_title, "Verify multi-factor authentication")
     |> assign(:mfa_mode, :challenge)
     |> assign(:mfa_challenge_mode, :totp)
     |> assign(:mfa_challenge_error, nil)
     |> assign(:mfa_recovery_form, to_form(%{"code" => ""}))}
  end

  # The proof kind (`@mfa_facts.enrollment_proof`) is read on the connected
  # mount only (IL-18); the dead render shows the page while it loads. An SSO
  # proof the callback left in the session skips straight to the authenticator
  # step — also connected-only, so the QR code the operator scans is the one
  # secret this socket holds.
  defp mount_enrollment(socket, sso_proof, return_to) do
    socket =
      socket
      |> assign(:page_title, "Set up multi-factor authentication")
      |> assign(:mfa_mode, :enrollment)
      |> assign(:return_to, return_to)
      |> assign(:mfa_facts, nil)
      |> assign(:mfa_recovery_codes, nil)
      |> assign(:codes_saved?, false)
      |> reset_enrollment()

    if connected?(socket) do
      {:ok, socket |> assign_mfa_facts() |> continue_sso_enrollment(sso_proof)}
    else
      {:ok, socket}
    end
  end

  defp continue_sso_enrollment(socket, proof) when is_binary(proof) do
    if socket.redirected,
      do: socket,
      else: socket |> MfaEnrollment.prepare_authenticator(proof) |> assign_mfa_form()
  end

  defp continue_sso_enrollment(socket, _proof), do: socket

  def render(assigns) do
    ~H"""
    <.auth_layout title="Multi-factor authentication">
      <p class="mb-6 text-sm text-zinc-400">
        <span class="font-semibold text-zinc-200">{@current_account.name}</span>
        <%= case @mfa_mode do %>
          <% :enrollment -> %>
            uses multi-factor authentication. Set up an authenticator app to continue.
          <% :challenge -> %>
            requires MFA. Enter an authenticator or recovery code to continue.
        <% end %>
      </p>

      <%= cond do %>
        <% @mfa_mode == :challenge -> %>
          <%= if @mfa_challenge_mode == :totp do %>
            <.simple_form for={%{}} phx-submit="verify_totp">
              <.code_input
                id="mfa-session-otp"
                name="otp"
                numeric
                label="Authenticator code"
                error={@mfa_challenge_error}
              />
              <:actions>
                <.button class="w-full" phx-disable-with="Verifying...">
                  Continue
                </.button>
              </:actions>
            </.simple_form>

            <.auth_footer_link event="use_recovery">
              <:lead>Can't use your authenticator?</:lead>
              Use a recovery code
            </.auth_footer_link>
          <% else %>
            <.simple_form for={@mfa_recovery_form} phx-submit="verify_recovery">
              <.input
                field={@mfa_recovery_form[:code]}
                type="text"
                label="Recovery code"
                autocomplete="one-time-code"
                required
              />
              <.error :if={@mfa_challenge_error}>{@mfa_challenge_error}</.error>
              <:actions>
                <.button class="w-full" phx-disable-with="Verifying...">
                  Continue
                </.button>
              </:actions>
            </.simple_form>

            <.auth_footer_link event="use_totp">
              <:lead>Have your authenticator?</:lead>
              Enter a code instead
            </.auth_footer_link>
          <% end %>
        <% @mfa_recovery_codes -> %>
          <div class="space-y-4">
            <.mfa_setup_progress step={3} />
            <.secret_reveal
              id="mfa-recovery-codes"
              title="Save your recovery codes"
              codes={@mfa_recovery_codes}
              download_name="emisar-recovery-codes.txt"
            >
              Use a recovery code if you can't access your authenticator. Each code works once.
              Save these somewhere safe—you won't be able to view them again.
              <:actions>
                <.recovery_code_acknowledgement
                  saved={@codes_saved?}
                  event="continue"
                  label="Continue"
                />
              </:actions>
            </.secret_reveal>
          </div>
        <% @mfa_enrollment_step == :email -> %>
          <.mfa_setup_progress step={1} />
          <.mfa_enrollment_email_verification
            email={@current_membership.email}
            form={@mfa_enrollment_email_form}
            error={@mfa_enrollment_email_error}
          >
            <:actions>
              <.button phx-disable-with="Verifying...">Verify email</.button>
              <%!-- Resending sends a real email, so it wears a bordered face (§7.47) —
                   the same grammar as the profile copy of this step. --%>
              <.button
                variant={:secondary}
                type="button"
                phx-click="resend_mfa_enrollment_email"
                phx-disable-with="Sending..."
              >
                Resend code
              </.button>
            </:actions>
          </.mfa_enrollment_email_verification>
        <% @mfa_enrollment_step == :totp -> %>
          <.mfa_setup_progress step={2} />
          <.mfa_enrollment
            qr_svg={@mfa_qr_svg}
            setup_key={@mfa_setup_key}
            form={@mfa_form}
            error={@mfa_error}
          >
            <:instructions>
              Scan this QR code with your authenticator app, then enter its 6-digit code.
            </:instructions>
            <:actions>
              <.button phx-disable-with="Enabling...">Enable MFA</.button>
            </:actions>
          </.mfa_enrollment>
        <% is_nil(@mfa_facts) -> %>
          <p role="status" class="text-sm text-zinc-400">Loading…</p>
        <% @mfa_facts.enrollment_proof == :email -> %>
          <div class="space-y-4">
            <p class="text-sm text-zinc-300">
              First verify your email, then connect your authenticator app.
            </p>
            <.error :if={@mfa_start_error}>{@mfa_start_error}</.error>
            <.button phx-click="start_mfa" phx-disable-with="Sending...">
              Email me a verification code
            </.button>
          </div>
        <% @mfa_facts.enrollment_proof == :sso -> %>
          <div class="space-y-4">
            <p class="text-sm text-zinc-300">
              First sign in again with {sso_provider_name(@current_auth)} to confirm it's you,
              then connect your authenticator app.
            </p>
            <.error :if={@mfa_start_error}>{@mfa_start_error}</.error>
            <.button href={~p"/app/#{@current_account}/mfa_setup/sso"} method="post">
              Verify with {sso_provider_name(@current_auth)}
            </.button>
          </div>
        <% true -> %>
          <.empty_state
            variant={:bare}
            tone={:danger}
            icon="state.locked"
            title="We can't confirm it's you from this session"
          >
            Setting up an authenticator needs a fresh proof of your own sign-in: a code to a
            verified email address, or a new sign-in through this workspace's identity provider.
            Neither is available here. Ask a workspace administrator to invite you again, or
            contact support@emisar.dev.
          </.empty_state>
      <% end %>
      <.auth_footer_link href={~p"/sign_out"} method="delete">
        Sign out
      </.auth_footer_link>
    </.auth_layout>
    """
  end

  def handle_event("verify_totp", %{"otp" => otp}, socket),
    do: verify_current_session(socket, {:totp, otp})

  def handle_event("verify_recovery", %{"code" => code}, socket),
    do: verify_current_session(socket, {:recovery_code, code})

  def handle_event("use_recovery", _params, socket) do
    {:noreply,
     socket |> assign(:mfa_challenge_mode, :recovery) |> assign(:mfa_challenge_error, nil)}
  end

  def handle_event("use_totp", _params, socket) do
    {:noreply, socket |> assign(:mfa_challenge_mode, :totp) |> assign(:mfa_challenge_error, nil)}
  end

  def handle_event("start_mfa", _params, socket) do
    case Auth.issue_mfa_enrollment_code(socket.assigns.current_subject) do
      {:ok, :sent} ->
        {:noreply,
         socket
         |> assign(:mfa_enrollment_step, :email)
         |> assign(:mfa_start_error, nil)
         |> assign(:mfa_enrollment_email_error, nil)}

      {:ok, :suppressed} ->
        {:noreply, assign(socket, :mfa_start_error, @email_suppressed_error)}

      {:error, :rate_limited} ->
        {:noreply, assign(socket, :mfa_start_error, MfaErrors.message(:email_rate_limited))}

      {:error, :email_unavailable} ->
        {:noreply, assign(socket, :mfa_start_error, @email_unavailable_error)}

      {:error, :mfa_already_enabled} ->
        {:noreply, remount(socket)}

      {:error, :unauthorized} ->
        {:noreply, UserAuth.reauthenticate(socket)}

      {:error, _reason} ->
        {:noreply, assign(socket, :mfa_start_error, @email_delivery_error)}
    end
  end

  def handle_event(
        "verify_mfa_enrollment_email",
        %{"mfa_enrollment" => %{"code" => code}},
        socket
      ) do
    if socket.assigns.mfa_enrollment_step == :email do
      socket = push_event(socket, "code:reset", %{id: "mfa-enrollment-email-code"})

      case Auth.verify_mfa_enrollment_code(
             String.trim(code || ""),
             socket.assigns.current_subject
           ) do
        {:ok, proof} ->
          {:noreply, socket |> MfaEnrollment.prepare_authenticator(proof) |> assign_mfa_form()}

        {:error, :invalid} ->
          {:noreply,
           assign(socket, :mfa_enrollment_email_error, MfaErrors.message(:email_code_invalid))}

        {:error, :rate_limited} ->
          {:noreply,
           assign(socket, :mfa_enrollment_email_error, MfaErrors.message(:rate_limited))}

        {:error, :email_unavailable} ->
          {:noreply,
           socket |> reset_enrollment() |> assign(:mfa_start_error, @email_unavailable_error)}

        {:error, :mfa_already_enabled} ->
          {:noreply, remount(socket)}

        {:error, :unauthorized} ->
          {:noreply, UserAuth.reauthenticate(socket)}

        {:error, _reason} ->
          {:noreply,
           assign(socket, :mfa_enrollment_email_error, "Could not verify that code. Try again.")}
      end
    else
      {:noreply, put_flash(socket, :error, MfaErrors.message(:email_verification_required))}
    end
  end

  def handle_event("resend_mfa_enrollment_email", _params, socket) do
    if socket.assigns.mfa_enrollment_step == :email do
      case Auth.issue_mfa_enrollment_code(socket.assigns.current_subject) do
        {:ok, :sent} ->
          {:noreply,
           socket
           |> assign(:mfa_enrollment_email_error, nil)
           |> put_flash(
             :info,
             "A new verification code was sent to #{socket.assigns.current_membership.email}."
           )
           |> push_event("code:reset", %{id: "mfa-enrollment-email-code"})}

        {:ok, :suppressed} ->
          {:noreply, assign(socket, :mfa_enrollment_email_error, @email_suppressed_error)}

        {:error, :rate_limited} ->
          {:noreply,
           assign(socket, :mfa_enrollment_email_error, MfaErrors.message(:email_rate_limited))}

        {:error, :mfa_already_enabled} ->
          {:noreply, remount(socket)}

        {:error, :unauthorized} ->
          {:noreply, UserAuth.reauthenticate(socket)}

        {:error, _reason} ->
          {:noreply, assign(socket, :mfa_enrollment_email_error, @email_delivery_error)}
      end
    else
      {:noreply, put_flash(socket, :error, MfaErrors.message(:email_verification_required))}
    end
  end

  def handle_event("confirm_mfa", %{"mfa" => %{"otp" => otp}}, socket) do
    secret = socket.assigns.mfa_secret

    if is_nil(secret) do
      {:noreply, put_flash(socket, :error, "Still preparing — try again in a second.")}
    else
      case Auth.enable_mfa(
             secret,
             otp,
             socket.assigns.mfa_enrollment_proof,
             socket.assigns.current_auth.token,
             socket.assigns.current_subject
           ) do
        {:ok, updated, recovery_codes} ->
          {:noreply,
           socket
           |> MfaEnrollment.assign_current_proof(updated)
           |> assign(:mfa_recovery_codes, recovery_codes)
           |> assign(:codes_saved?, false)
           |> reset_enrollment()}

        {:error, :invalid_otp} ->
          {:noreply,
           socket
           |> assign(:mfa_error, MfaErrors.message(:invalid_otp))
           |> push_event("code:reset", %{id: "mfa-otp"})}

        {:error, :mfa_enrollment_proof_stale} ->
          {:noreply,
           socket
           |> reset_enrollment()
           |> assign(:mfa_start_error, MfaErrors.message(:mfa_enrollment_proof_stale))}

        {:error, :mfa_already_enabled} ->
          {:noreply, remount(socket)}

        {:error, reason} when reason in [:unauthorized, :session_not_found] ->
          {:noreply, UserAuth.reauthenticate(socket)}

        {:error, _changeset} ->
          {:noreply, assign(socket, :mfa_error, MfaErrors.message(:enable_failed))}
      end
    end
  end

  def handle_event("continue", _params, socket) do
    if socket.assigns.mfa_recovery_codes && socket.assigns.codes_saved? do
      {:noreply, push_navigate(socket, to: socket.assigns.return_to)}
    else
      {:noreply, put_flash(socket, :error, MfaErrors.message(:recovery_codes_unsaved))}
    end
  end

  def handle_event("toggle_codes_saved", _params, socket) do
    if socket.assigns.mfa_recovery_codes do
      {:noreply, update(socket, :codes_saved?, &(not &1))}
    else
      {:noreply, socket}
    end
  end

  defp verify_current_session(socket, factor) do
    socket = push_event(socket, "code:reset", %{id: "mfa-session-otp"})

    with {:ok, proof} <-
           Auth.verify_current_session_mfa_challenge(
             factor,
             socket.assigns.current_subject
           ),
         {:ok, _session} <-
           Auth.complete_current_session_mfa(
             proof,
             socket.assigns.current_auth.token,
             socket.assigns.current_subject
           ) do
      {:noreply, push_navigate(socket, to: ~p"/app/#{socket.assigns.current_account}")}
    else
      {:error, :rate_limited} ->
        {:noreply, assign(socket, :mfa_challenge_error, MfaErrors.message(:rate_limited))}

      {:error, reason} when reason in [:unauthorized, :session_not_found] ->
        {:noreply, UserAuth.reauthenticate(socket)}

      {:error, :mfa_proof_stale} ->
        {:noreply,
         socket
         |> put_flash(:error, "Your MFA settings changed. Verify the current factor again.")
         |> remount()}

      {:error, _reason} ->
        {:noreply,
         assign(
           socket,
           :mfa_challenge_error,
           MfaErrors.challenge(socket.assigns.mfa_challenge_mode)
         )}
    end
  end

  # Facts come from the live session and the current Member row, never a held
  # snapshot. Expiry during a mounted page is a sign-in step, not a crash.
  defp assign_mfa_facts(socket) do
    case Auth.mfa_facts(socket.assigns.current_subject) do
      {:ok, facts} -> assign(socket, :mfa_facts, facts)
      {:error, :unauthorized} -> UserAuth.reauthenticate(socket)
    end
  end

  # The Member's state changed under this page (enrolled elsewhere, a factor
  # reset): a fresh mount re-decides between enrollment and the challenge.
  defp remount(socket),
    do: push_navigate(socket, to: ~p"/app/#{socket.assigns.current_account}/mfa_setup")

  defp reset_enrollment(socket) do
    socket
    |> MfaEnrollment.reset()
    |> assign(:mfa_start_error, nil)
    |> assign_mfa_enrollment_email_form()
    |> assign_mfa_form()
  end

  # The identity provider behind this SSO session; `with_preloaded_authority/1`
  # carries it on the session row.
  defp sso_provider_name(%Auth.UserToken{user_identity: %{provider: %{name: name}}})
       when is_binary(name),
       do: name

  defp sso_provider_name(_auth), do: "your identity provider"

  defp assign_mfa_form(socket) do
    assign(socket, :mfa_form, to_form(%{"otp" => ""}, as: "mfa"))
  end

  defp assign_mfa_enrollment_email_form(socket) do
    assign(socket, :mfa_enrollment_email_form, to_form(%{"code" => ""}, as: "mfa_enrollment"))
  end
end
