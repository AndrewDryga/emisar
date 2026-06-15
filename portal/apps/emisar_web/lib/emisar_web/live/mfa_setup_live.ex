defmodule EmisarWeb.MfaSetupLive do
  @moduledoc """
  Enforced-MFA enrollment interstitial. When an account requires 2FA
  (`account.require_mfa`) and the signed-in member hasn't enrolled,
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
  alias EmisarWeb.MfaQr

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    account = socket.assigns.current_account

    cond do
      # Nothing to enroll — already compliant (or the account stopped
      # enforcing while this tab was open). Don't strand the user here.
      user.mfa_enabled_at != nil or not account.require_mfa ->
        {:ok, push_navigate(socket, to: ~p"/app")}

      # The secret must be generated exactly once, on the connected
      # mount: the static render runs in a separate process, so a QR
      # generated there would differ from the one the form verifies
      # against — the user would scan a code that can never confirm.
      connected?(socket) ->
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

      true ->
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
            <div class="rounded-lg border border-amber-500/30 bg-amber-500/10 p-4">
              <h3 class="text-sm font-semibold text-amber-100">Save your recovery codes</h3>
              <p class="mt-1 text-xs text-amber-200/80">
                Each code signs you in once if you lose your authenticator. They are only
                shown now.
              </p>
              <ul class="mt-3 grid grid-cols-2 gap-1 font-mono text-xs text-amber-100">
                <li :for={code <- @mfa_recovery_codes}>{code}</li>
              </ul>
            </div>

            <textarea id="mfa-recovery-codes-blob" class="hidden" readonly aria-hidden="true">{Enum.join(@mfa_recovery_codes, "\n")}</textarea>

            <div class="flex flex-wrap items-center gap-3">
              <.copy_button
                target="#mfa-recovery-codes-blob"
                class="bg-zinc-800 px-3 py-1.5 text-zinc-100 hover:bg-zinc-700 font-medium"
              >
                Copy codes
              </.copy_button>
              <%!-- A real file beats the volatile clipboard for a credential
                   the operator must keep — clipboards get overwritten. --%>
              <a
                href={"data:text/plain;charset=utf-8," <> URI.encode(Enum.join(@mfa_recovery_codes, "\n"))}
                download="emisar-recovery-codes.txt"
                class="rounded-lg bg-zinc-800 px-3 py-1.5 text-sm font-medium text-zinc-100 hover:bg-zinc-700"
              >
                Download .txt
              </a>
            </div>

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
          <div class="space-y-4">
            <div class="flex flex-col items-center gap-2">
              <div class="rounded-lg bg-white p-3 [&>svg]:block [&>svg]:h-60 [&>svg]:w-60">
                {raw(@mfa_qr_svg)}
              </div>
              <p class="text-[11px] text-zinc-500">Scan with your authenticator</p>
            </div>

            <details class="rounded-lg border border-zinc-800 bg-zinc-950/40">
              <summary class="cursor-pointer px-3 py-2 text-xs font-medium text-zinc-400 hover:text-zinc-200">
                Can't scan? Use a setup URI
              </summary>
              <div class="flex items-center gap-2 border-t border-zinc-800 p-3">
                <code id="mfa-uri" class="flex-1 break-all font-mono text-[11px] text-zinc-200">
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
                <.button phx-disable-with="Verifying...">Confirm and continue</.button>
              </:actions>
            </.simple_form>
          </div>
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
