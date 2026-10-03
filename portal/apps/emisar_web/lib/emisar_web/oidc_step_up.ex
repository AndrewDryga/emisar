defmodule EmisarWeb.OIDCStepUp do
  @moduledoc """
  The socket state the SSO connection verification step-up walks through on
  `SSOSettingsLive`: an administrator proves a connection by actually signing
  in through it, after a fresh local proof of their own credential (an
  authenticator code, or a code emailed to their verified address).

  The step map is the page's own record of which connection is being verified;
  `begin/3` adds the factor the domain chose, and the later transitions read
  back `:provider_id`, `:provider_name` and `:factor`.

  The sentences a spent attempt budget shows live in `EmisarWeb.MfaErrors`.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3]
  alias Emisar.Auth
  alias EmisarWeb.{MfaErrors, OIDCIdentityHandoff}

  @doc """
  Opens a step-up for `step`, asking the domain which factor proves it.

  `unavailable_message` is the flash for a refusal the operator cannot act on,
  so the page names its own action there.
  """
  def begin(socket, step, unavailable_message) do
    case Auth.begin_oidc_identity_step_up(
           step.provider_id,
           step.provider_name,
           socket.assigns.current_subject
         ) do
      {:ok, factor} ->
        socket
        |> assign(:oidc_step, Map.put(step, :factor, factor))
        |> assign(:oidc_step_error, nil)
        |> assign(:oidc_step_form, to_form(%{"code" => ""}, as: "oidc_step"))
        |> flash_issued_code(factor)

      # The Member's address can't receive the confirmation code, so the step-up
      # can't proceed — tell them plainly rather than showing a code prompt.
      {:error, :delivery_suppressed} ->
        put_flash(socket, :error, undeliverable_message(socket))

      {:error, :rate_limited} ->
        put_flash(socket, :error, MfaErrors.message(:email_rate_limited))

      {:error, _reason} ->
        put_flash(socket, :error, unavailable_message)
    end
  end

  defp flash_issued_code(socket, :email),
    do: put_flash(socket, :info, "We emailed a confirmation code to your address.")

  defp flash_issued_code(socket, :mfa), do: socket

  @doc """
  Spends `code` on the open step-up, returning `{:ok, proof}` or the sentence
  to show under the code box.
  """
  def confirm(step, code, subject) do
    case Auth.confirm_oidc_identity_step_up(step.provider_id, String.trim(code || ""), subject) do
      {:ok, proof} ->
        {:ok, proof}

      {:error, :rate_limited} ->
        {:error, MfaErrors.message(:rate_limited)}

      {:error, :replay} ->
        {:error, "That authenticator code was already used. Wait for the next code."}

      {:error, _reason} ->
        {:error, wrong_code_message(step.factor)}
    end
  end

  defp wrong_code_message(:mfa), do: MfaErrors.message(:step_up_factor_invalid)
  defp wrong_code_message(:email), do: MfaErrors.message(:email_code_invalid)

  @doc "Issues a replacement code for an emailed step-up already in progress."
  def resend(socket, step, code_input_id) do
    case Auth.resend_oidc_identity_step_up_code(
           step.provider_id,
           step.provider_name,
           socket.assigns.current_subject
         ) do
      {:ok, :sent} ->
        socket
        |> assign(:oidc_step_error, nil)
        |> push_event("code:reset", %{id: code_input_id})
        |> put_flash(:info, "We sent a new code to #{member_email(socket)}.")

      # The address won't accept mail, so no code can arrive — say so and drop
      # back to the page instead of waiting for a code.
      {:ok, :suppressed} ->
        socket
        |> reset()
        |> put_flash(:error, undeliverable_message(socket))

      {:error, :rate_limited} ->
        assign(socket, :oidc_step_error, MfaErrors.message(:email_rate_limited))

      {:error, _reason} ->
        assign(socket, :oidc_step_error, "Couldn't send a new code. Try again.")
    end
  end

  @doc """
  Arms the dialog's form to post a just-earned proof to the identity controller.

  The proof only travels as a signed handoff bound to this Member, workspace and
  session, so the browser carries it to the controller that can write the OIDC
  transaction without it ever being a value the page could be tricked into
  re-using.
  """
  def handoff(socket, step, proof) do
    payload = %{
      actor_membership_id: socket.assigns.current_subject.membership_id,
      actor_session_token_digest: socket.assigns.current_auth.token,
      account_id: socket.assigns.current_account.id,
      provider_id: step.provider_id,
      proof: proof
    }

    socket
    |> assign(:oidc_handoff, OIDCIdentityHandoff.sign(payload))
    |> assign(:oidc_trigger_submit, true)
    |> assign(:oidc_step_error, nil)
  end

  @doc """
  Returns the step-up to its idle state, dropping any earned handoff.

  A fresh form rather than the operator's rejected code: the next step-up starts
  from an empty box, and a stale handoff must never survive to arm a later one.
  """
  def reset(socket) do
    socket
    |> assign(:oidc_step, nil)
    |> assign(:oidc_step_error, nil)
    |> assign(:oidc_step_form, to_form(%{"code" => ""}, as: "oidc_step"))
    |> assign(:oidc_handoff, nil)
    |> assign(:oidc_trigger_submit, false)
  end

  defp undeliverable_message(socket), do: "We can't deliver a code to #{member_email(socket)}."

  defp member_email(socket), do: socket.assigns.current_membership.email || "your address"
end
