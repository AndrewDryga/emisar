defmodule EmisarWeb.MfaSetupLive do
  @moduledoc """
  Enforced-MFA enrollment interstitial. When an account requires 2FA
  (`account.settings.require_mfa`) and the signed-in member hasn't enrolled,
  `UserAuth.on_mount(:ensure_mfa_compliant)` forwards every /app mount
  here — most importantly the invite-accept flow, so a fresh invitee
  enrolls as the natural second step before first seeing the dashboard.

  Enrollment starts immediately (no "set up" button — the user is here
  for exactly that), confirms a TOTP code, shows the recovery codes
  once, then continues to /app. Voluntary management (disable,
  regenerate codes) stays on the profile page.
  """
  use EmisarWeb, :live_view
  alias Emisar.Auth
  alias EmisarWeb.{MfaQr, UserAuth}

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    account = socket.assigns.current_account

    # Delegate the enroll-or-leave decision to the shared predicate so this
    # interstitial can't drift from the on_mount hooks / the controller plug —
    # in particular the MFA exemption stays ACCOUNT-SCOPED (a session SSO-authed
    # via another account's IdP is NOT exempt here and enrolls).
    case UserAuth.account_compliance(account, socket.assigns[:current_auth], user) do
      :mfa_required ->
        mount_enrollment(socket, user)

      :sso_required ->
        # The :ensure_sso_compliant on_mount already bounced a non-SSO session on
        # a require_sso+require_mfa account; never enroll a factor before SSO is
        # satisfied — belt and suspenders.
        {:ok, push_navigate(socket, to: ~p"/app/#{account}/sso_required")}

      :ok ->
        # Already compliant (enrolled, not enforcing, or an MFA-satisfying SSO
        # session FOR THIS account) — don't strand the user in enrollment.
        {:ok, push_navigate(socket, to: ~p"/app")}
    end
  end

  # The secret must be generated exactly once, on the connected mount: the static
  # render runs in a separate process, so a QR generated there would differ from
  # the one the form verifies against — the user would scan a code that can never
  # confirm.
  defp mount_enrollment(socket, user) do
    if connected?(socket) do
      secret = Auth.generate_mfa_secret()
      uri = MfaQr.provisioning_uri(user.email, secret)

      {:ok,
       socket
       |> assign(:page_title, "Set up two-factor authentication")
       |> assign(:mfa_secret, secret)
       |> assign(:mfa_uri, uri)
       |> assign(:mfa_qr_svg, MfaQr.svg(uri))
       |> assign(:mfa_recovery_codes, nil)
       |> assign_mfa_form()}
    else
      {:ok,
       socket
       |> assign(:page_title, "Set up two-factor authentication")
       |> assign(:mfa_secret, nil)
       |> assign(:mfa_uri, nil)
       |> assign(:mfa_qr_svg, nil)
       |> assign(:mfa_recovery_codes, nil)
       |> assign_mfa_form()}
    end
  end

  def render(assigns) do
    ~H"""
    <.auth_layout title="Two-factor authentication required">
      <p class="mb-6 text-sm text-zinc-400">
        <span class="font-semibold text-zinc-200">{@current_account.name}</span>
        requires two-factor authentication for every member. Set it up now to continue
        to your dashboard.
      </p>

      <%= cond do %>
        <% @mfa_recovery_codes -> %>
          <div class="space-y-4">
            <.secret_reveal
              id="mfa-recovery-codes"
              variant={:card}
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
        <% @mfa_uri -> %>
          <.mfa_enrollment qr_svg={@mfa_qr_svg} uri={@mfa_uri} form={@mfa_form}>
            <:actions>
              <.button phx-disable-with="Verifying...">Confirm and continue</.button>
            </:actions>
          </.mfa_enrollment>
        <% true -> %>
          <p class="text-sm text-zinc-500">Preparing your setup code…</p>
      <% end %>
    </.auth_layout>
    """
  end

  def handle_event("confirm_mfa", %{"mfa" => %{"otp" => otp}}, socket) do
    secret = socket.assigns.mfa_secret

    if is_nil(secret) do
      {:noreply, put_flash(socket, :error, "Still preparing — try again in a second.")}
    else
      case Auth.enable_mfa(secret, otp, socket.assigns.current_subject) do
        {:ok, updated, recovery_codes} ->
          {:noreply,
           socket
           |> assign(:current_user, updated)
           |> assign(:mfa_recovery_codes, recovery_codes)
           |> assign(:codes_saved?, false)
           |> assign(:mfa_secret, nil)
           |> assign(:mfa_uri, nil)
           |> assign(:mfa_qr_svg, nil)}

        {:error, :invalid_otp} ->
          {:noreply, put_flash(socket, :error, "That code didn't match — try the next one.")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not enable MFA.")}
      end
    end
  end

  def handle_event("continue", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/app")}
  end

  def handle_event("toggle_codes_saved", _params, socket) do
    {:noreply, update(socket, :codes_saved?, &(not &1))}
  end

  defp assign_mfa_form(socket) do
    assign(socket, :mfa_form, to_form(%{"otp" => ""}, as: "mfa"))
  end
end
