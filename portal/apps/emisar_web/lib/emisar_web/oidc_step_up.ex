defmodule EmisarWeb.OIDCStepUp do
  @moduledoc """
  The socket state an OIDC step-up walks through, shared by the two pages that
  run one: `ProfileLive` when a member links or removes their own sign-in
  method, `SSOSettingsLive` when an administrator proves a connection by
  actually signing in through it.

  Both drive the same `Emisar.Auth` functions in the same order over the same
  `:oidc_step*` assigns, and each had grown its own copy of every step — `reset/1`
  was byte-identical, and the wrong-code and resend sentences had been written
  twice under two private names for the same words.

  What stays with each page is what it is confirming: the purpose it proves,
  what it spends the proof on, and the sentence naming its own action when the
  step-up cannot start — which is why `begin/4` takes that sentence from the
  caller instead of making the profile page borrow the administrator page's
  "sign-in verification" wording.

  The step map is the page's own record of what is being confirmed; `begin/4`
  adds the purpose and the factor the domain chose, and the later transitions
  read back `:provider_id`, `:provider_name`, `:purpose`, and `:factor`.

  The sentences a spent attempt budget shows live in `EmisarWeb.MfaErrors`.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]
  alias Emisar.Auth
  alias EmisarWeb.{MfaErrors, OIDCIdentityHandoff}

  @doc """
  Opens a step-up for `step`, asking the domain which factor proves it.

  `unavailable_message` is the flash for a refusal the operator cannot act on,
  so each page names its own action there.
  """
  def begin(socket, step, purpose, unavailable_message) do
    case Auth.begin_oidc_identity_step_up(
           step.provider_id,
           step.provider_name,
           purpose,
           socket.assigns.current_subject
         ) do
      {:ok, factor} ->
        socket
        |> assign(:oidc_step, Map.merge(step, %{purpose: purpose, factor: factor}))
        |> assign(:oidc_step_error, nil)
        |> assign(:oidc_step_form, to_form(%{"code" => ""}, as: "oidc_step"))
        |> flash_issued_code(factor)

      # The account email can't receive the confirmation code, so the step-up
      # can't proceed — tell them plainly rather than showing a code prompt.
      {:error, :delivery_suppressed} ->
        put_flash(
          socket,
          :error,
          "We can't deliver a code to #{socket.assigns.current_user.email}."
        )

      {:error, :rate_limited} ->
        put_flash(socket, :error, MfaErrors.message(:email_rate_limited))

      {:error, _reason} ->
        put_flash(socket, :error, unavailable_message)
    end
  end

  defp flash_issued_code(socket, :email),
    do: put_flash(socket, :info, "We emailed a confirmation code to your current address.")

  defp flash_issued_code(socket, :mfa), do: socket

  @doc """
  Spends `code` on the open step-up, returning `{:ok, proof}` or the sentence
  to show under the code box.
  """
  def confirm(step, code, subject) do
    case Auth.confirm_oidc_identity_step_up(
           step.provider_id,
           step.purpose,
           String.trim(code || ""),
           subject
         ) do
      {:ok, proof} -> {:ok, proof}
      {:error, :rate_limited} -> {:error, MfaErrors.message(:rate_limited)}
      {:error, :replay} -> {:error, "That authenticator code was already used."}
      {:error, _reason} -> {:error, wrong_code_message(step.factor)}
    end
  end

  defp wrong_code_message(:mfa),
    do: "That authenticator or recovery code didn't match. Try again."

  defp wrong_code_message(:email),
    do: "That confirmation code is wrong or expired. Try again, or resend it."

  @doc "Issues a replacement code for an emailed step-up already in progress."
  def resend(socket, step) do
    case Auth.resend_oidc_identity_step_up_code(
           step.provider_id,
           step.provider_name,
           step.purpose,
           socket.assigns.current_subject
         ) do
      {:ok, :sent} ->
        socket
        |> assign(:oidc_step_error, nil)
        |> put_flash(:info, "We sent a new code to #{socket.assigns.current_user.email}.")

      # The account email won't accept mail, so no code can arrive — say so and
      # drop back to the page instead of waiting for a code.
      {:ok, :suppressed} ->
        socket
        |> reset()
        |> put_flash(
          :error,
          "We can't deliver a code to #{socket.assigns.current_user.email}."
        )

      {:error, :rate_limited} ->
        assign(socket, :oidc_step_error, MfaErrors.message(:email_rate_limited))

      {:error, _reason} ->
        assign(socket, :oidc_step_error, "Couldn't send a new code. Try again.")
    end
  end

  @doc """
  Arms the dialog's form to post a just-earned proof to the identity controller.

  The proof only travels as a signed handoff, so the browser carries it to the
  controller that can write the OIDC transaction without it ever being a value
  the page could be tricked into re-using.
  """
  def handoff(socket, step, proof) do
    payload = %{
      actor_id: socket.assigns.current_user.id,
      actor_membership_id: socket.assigns.current_subject.membership_id,
      actor_session_token_digest: socket.assigns.current_auth.token,
      account_id: socket.assigns.current_account.id,
      provider_id: step.provider_id,
      purpose: step.purpose,
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
end
