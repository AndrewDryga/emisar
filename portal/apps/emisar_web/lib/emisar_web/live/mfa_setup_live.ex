defmodule EmisarWeb.MfaSetupLive do
  @moduledoc """
  Enforced-MFA interstitial. When an account requires MFA and this session has
  not proved the current factor, `UserAuth.on_mount(:ensure_account_compliant)`
  forwards every /app mount here. A fresh member enrolls; an already-enrolled
  member verifies TOTP or a recovery code for this browser.

  Enrollment first requires an explicit current-inbox verification, then
  confirms a TOTP code, shows the recovery codes once, and continues to /app.
  Voluntary management (disable, regenerate codes) stays on the profile page.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Accounts, Auth}
  alias EmisarWeb.{MfaErrors, MfaQr}

  @mfa_rate_limit_error "Too many attempts. Wait a few minutes, then try again."
  @email_issue_rate_limit_error "Too many code requests. Wait up to 15 minutes, then try again."
  @email_unavailable_error "Your identity provider did not supply an email address. Ask your administrator to update it, then sign in again."
  @email_suppressed_error "Emisar cannot deliver mail to your current address. Contact support to restore email delivery before setting up MFA."
  @email_delivery_error "We could not deliver the verification code. Try again. If it keeps failing, contact support."

  def mount(_params, session, socket) do
    user = socket.assigns.current_user
    account = socket.assigns.current_account

    # Delegate the enroll-or-leave decision to the shared domain policy so this
    # interstitial can't drift from the on_mount hooks / the controller plug —
    # in particular the MFA exemption stays ACCOUNT-SCOPED (a session SSO-authed
    # via another account's IdP is NOT exempt here and must prove local MFA).
    case Accounts.ensure_account_compliant(account, socket.assigns.current_subject) do
      {:error, :mfa_required} ->
        mount_required_mfa(socket, user, session["user_token"])

      {:error, :sso_required} ->
        # The :ensure_sso_compliant on_mount already bounced a non-SSO session on
        # a require_sso+require_mfa account; never enroll a factor before SSO is
        # satisfied — belt and suspenders.
        {:ok, push_navigate(socket, to: ~p"/app/#{account}/sso_required")}

      # Already compliant (current local proof, not enforcing, or an
      # MFA-satisfying SSO session FOR THIS account) — don't strand the user.
      :ok ->
        {:ok, push_navigate(socket, to: ~p"/app")}

      {:error, reason} when reason in [:not_found, :unauthorized] ->
        raise EmisarWeb.NotFoundError
    end
  end

  defp mount_required_mfa(socket, user, presented_token) do
    mode = if is_nil(user.mfa_enabled_at), do: :enrollment, else: :challenge

    title =
      if mode == :enrollment,
        do: "Set up multi-factor authentication",
        else: "Verify multi-factor authentication"

    {:ok,
     socket
     |> assign(:page_title, title)
     |> assign(:mfa_mode, mode)
     |> assign(:current_session_token, presented_token)
     |> assign(:mfa_recovery_codes, nil)
     |> assign(:mfa_challenge_mode, :totp)
     |> assign(:mfa_challenge_error, nil)
     |> assign(:mfa_recovery_form, to_form(%{"code" => ""}))
     |> reset_mfa_enrollment()}
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Multi-factor authentication required">
      <p class="mb-6 text-sm text-zinc-400">
        <span class="font-semibold text-zinc-200">{@current_account.name}</span>
        requires multi-factor authentication for every member.
        <%= if @mfa_mode == :enrollment do %>
          Set it up now to continue to your dashboard.
        <% else %>
          Verify this session to continue to your dashboard.
        <% end %>
        Learn why we require it in the <.link
          href={~p"/security"}
          class="text-zinc-400 underline hover:text-zinc-200"
        >
          Security overview</.link>.
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
                  Verify <span aria-hidden="true">→</span>
                </.button>
              </:actions>
            </.simple_form>

            <.mode_switch event="use_recovery" lead="Lost your device?">
              Use a recovery code
            </.mode_switch>
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
                  Verify <span aria-hidden="true">→</span>
                </.button>
              </:actions>
            </.simple_form>

            <.mode_switch event="use_totp" lead="Have your authenticator?">
              Enter a code instead
            </.mode_switch>
          <% end %>
        <% @mfa_recovery_codes -> %>
          <div class="space-y-4">
            <.secret_reveal
              id="mfa-recovery-codes"
              title="Save your recovery codes"
              codes={@mfa_recovery_codes}
              download_name="emisar-recovery-codes.txt"
            >
              Each code signs you in once if you lose your authenticator. They are only
              shown now.
            </.secret_reveal>

            <%!-- Gate Continue behind an explicit acknowledgement: an
                 MFA-required member who skips saving these and later loses
                 their authenticator is permanently locked out. --%>
            <.checkbox
              class="flex items-center gap-2 text-xs text-zinc-300"
              phx-click="toggle_codes_saved"
              checked={@codes_saved?}
              label="I've saved my recovery codes somewhere safe"
            />
            <.button
              phx-click="continue"
              phx-disable-with="Loading..."
              disabled={not @codes_saved?}
              class="disabled:cursor-not-allowed disabled:opacity-50"
            >
              Continue to dashboard <span aria-hidden="true">→</span>
            </.button>
          </div>
        <% @mfa_enrollment_step == :email -> %>
          <.mfa_enrollment_email_verification
            email={@current_user.email}
            form={@mfa_enrollment_email_form}
            error={@mfa_enrollment_email_error}
          >
            <:actions>
              <.button phx-disable-with="Verifying...">Verify email</.button>
              <%!-- Resending sends a real email, so it wears a bordered face (§7.47) —
                   the same grammar as the profile copy of this step. --%>
              <.button variant={:secondary} type="button" phx-click="resend_mfa_enrollment_email">
                Resend code
              </.button>
            </:actions>
          </.mfa_enrollment_email_verification>
        <% @mfa_uri -> %>
          <.mfa_enrollment qr_svg={@mfa_qr_svg} uri={@mfa_uri} form={@mfa_form} error={@mfa_error}>
            <:actions>
              <.button phx-disable-with="Verifying...">Confirm and continue</.button>
            </:actions>
          </.mfa_enrollment>
        <% true -> %>
          <div class="space-y-4">
            <p class="text-sm text-zinc-300">
              First verify your current email address. We will not reveal an authenticator secret
              until that proof succeeds.
            </p>
            <.error :if={@mfa_start_error}>{@mfa_start_error}</.error>
            <.button phx-click="start_mfa" phx-disable-with="Sending...">
              Email me a verification code
            </.button>
          </div>
      <% end %>
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
        {:noreply, assign(socket, :mfa_start_error, @email_issue_rate_limit_error)}

      {:error, :email_unavailable} ->
        {:noreply, assign(socket, :mfa_start_error, @email_unavailable_error)}

      {:error, :mfa_already_enabled} ->
        {:noreply, push_navigate(socket, to: ~p"/app/mfa_setup")}

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
      case Auth.verify_mfa_enrollment_code(
             String.trim(code || ""),
             socket.assigns.current_subject
           ) do
        {:ok, proof} ->
          {:noreply, prepare_mfa_authenticator(socket, proof)}

        {:error, :invalid} ->
          {:noreply,
           assign(
             socket,
             :mfa_enrollment_email_error,
             "That code is wrong or expired. Try again."
           )}

        {:error, :rate_limited} ->
          {:noreply, assign(socket, :mfa_enrollment_email_error, @mfa_rate_limit_error)}

        {:error, :email_unavailable} ->
          {:noreply,
           socket
           |> reset_mfa_enrollment()
           |> assign(:mfa_start_error, @email_unavailable_error)}

        {:error, :mfa_already_enabled} ->
          {:noreply, push_navigate(socket, to: ~p"/app/mfa_setup")}

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
          {:noreply, assign(socket, :mfa_enrollment_email_error, nil)}

        {:ok, :suppressed} ->
          {:noreply, assign(socket, :mfa_enrollment_email_error, @email_suppressed_error)}

        {:error, :rate_limited} ->
          {:noreply, assign(socket, :mfa_enrollment_email_error, @email_issue_rate_limit_error)}

        {:error, :mfa_already_enabled} ->
          {:noreply, push_navigate(socket, to: ~p"/app/mfa_setup")}

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
             socket.assigns.current_session_token,
             socket.assigns.current_subject
           ) do
        {:ok, updated, recovery_codes} ->
          {:noreply,
           socket
           |> assign(:current_user, updated)
           |> assign_current_mfa_proof(updated)
           |> assign(:mfa_recovery_codes, recovery_codes)
           |> assign(:codes_saved?, false)
           |> reset_mfa_enrollment()}

        {:error, :invalid_otp} ->
          {:noreply, assign(socket, :mfa_error, MfaErrors.message(:invalid_otp))}

        {:error, :mfa_enrollment_proof_stale} ->
          {:noreply,
           socket
           |> reset_mfa_enrollment()
           |> assign(:mfa_start_error, MfaErrors.message(:mfa_enrollment_proof_stale))}

        {:error, :mfa_already_enabled} ->
          {:noreply, push_navigate(socket, to: ~p"/app/mfa_setup")}

        {:error, :session_not_found} ->
          {:noreply,
           socket
           |> put_flash(:error, MfaErrors.message(:session_not_found))
           |> redirect(to: ~p"/sign_in/magic")}

        {:error, _changeset} ->
          {:noreply, assign(socket, :mfa_error, MfaErrors.message(:enable_failed))}
      end
    end
  end

  def handle_event("continue", _params, socket) do
    if socket.assigns.mfa_recovery_codes && socket.assigns.codes_saved? do
      {:noreply, push_navigate(socket, to: ~p"/app")}
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
    with {:ok, proof} <-
           Auth.verify_current_session_mfa_challenge(
             factor,
             socket.assigns.current_subject
           ),
         {:ok, _session} <-
           Auth.complete_current_session_mfa(
             proof,
             socket.assigns.current_session_token,
             socket.assigns.current_subject
           ) do
      {:noreply, push_navigate(socket, to: ~p"/app")}
    else
      {:error, :rate_limited} ->
        {:noreply, assign(socket, :mfa_challenge_error, @mfa_rate_limit_error)}

      {:error, :session_not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Your session changed. Sign in again to continue.")
         |> redirect(to: ~p"/sign_in/magic")}

      {:error, :mfa_proof_stale} ->
        {:noreply,
         socket
         |> put_flash(:error, "Your MFA settings changed. Verify the current factor again.")
         |> push_navigate(to: ~p"/app/mfa_setup")}

      {:error, _reason} ->
        {:noreply,
         assign(
           socket,
           :mfa_challenge_error,
           challenge_error(socket.assigns.mfa_challenge_mode)
         )}
    end
  end

  defp challenge_error(:totp),
    do: "That code didn't match. Check your authenticator app and try again."

  defp challenge_error(:recovery),
    do: "That recovery code didn't match or has already been used."

  defp assign_current_mfa_proof(socket, user) do
    subject = %{
      socket.assigns.current_subject
      | actor: user,
        mfa: true,
        mfa_enrollment_verified_at: user.mfa_enabled_at
    }

    auth = %{
      socket.assigns.current_auth
      | mfa_enrollment_verified_at: user.mfa_enabled_at
    }

    socket
    |> assign(:current_subject, subject)
    |> assign(:current_auth, auth)
  end

  attr :event, :string, required: true
  attr :lead, :string, required: true
  slot :inner_block, required: true

  defp mode_switch(assigns) do
    ~H"""
    <p class="mt-6 text-center text-sm text-zinc-400">
      {@lead}
      <button
        type="button"
        phx-click={@event}
        class="font-medium text-brand-400 hover:text-brand-300"
      >
        {render_slot(@inner_block)}
      </button>
    </p>
    """
  end

  defp assign_mfa_form(socket) do
    assign(socket, :mfa_form, to_form(%{"otp" => ""}, as: "mfa"))
  end

  defp assign_mfa_enrollment_email_form(socket) do
    assign(socket, :mfa_enrollment_email_form, to_form(%{"code" => ""}, as: "mfa_enrollment"))
  end

  defp prepare_mfa_authenticator(socket, proof) do
    secret = Auth.generate_mfa_secret()
    uri = MfaQr.provisioning_uri(socket.assigns.current_user.email, secret)

    socket
    |> assign(:mfa_enrollment_step, :totp)
    |> assign(:mfa_enrollment_proof, proof)
    |> assign(:mfa_secret, secret)
    |> assign(:mfa_uri, uri)
    |> assign(:mfa_qr_svg, MfaQr.svg(uri))
    |> assign(:mfa_error, nil)
    |> assign_mfa_form()
  end

  defp reset_mfa_enrollment(socket) do
    socket
    |> assign(:mfa_enrollment_step, :idle)
    |> assign(:mfa_enrollment_proof, nil)
    |> assign(:mfa_enrollment_email_error, nil)
    |> assign(:mfa_start_error, nil)
    |> assign(:mfa_secret, nil)
    |> assign(:mfa_uri, nil)
    |> assign(:mfa_qr_svg, nil)
    |> assign(:mfa_error, nil)
    |> assign(:codes_saved?, false)
    |> assign_mfa_enrollment_email_form()
    |> assign_mfa_form()
  end
end
