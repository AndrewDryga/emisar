defmodule EmisarWeb.MfaEnrollment do
  @moduledoc """
  The socket state an MFA enrollment walks through, shared by the two pages that
  run it: `MfaSetupLive` when an account enforces MFA, `ProfileLive` when a
  member opts in themselves.

  Both drive the same `Emisar.Auth` functions in the same order, and each had
  grown its own copy of these steps — `assign_current_mfa_proof/2` was
  byte-identical in both, and `prepare_authenticator/2` differed only by whether
  `MfaQr` was aliased.

  What stays with each page is its FORMS. `assign_mfa_form/1` and
  `assign_mfa_enrollment_email_form/1` are per-page, so these functions set the
  enrollment state and the caller pipes its own form assigns after — which also
  keeps the extra state the forced interstitial carries (`:mfa_start_error`,
  `:codes_saved?`) out of a shared reset that would silently invent those keys
  on the profile page.

  The sentences an enrollment failure shows live in `EmisarWeb.MfaErrors`.
  """

  import Phoenix.Component, only: [assign: 3]
  alias Emisar.Auth
  alias EmisarWeb.MfaQr

  @doc """
  Moves the enrollment to its authenticator step, minting a fresh secret.

  A new secret every time is deliberate: an enrollment that was abandoned and
  restarted must not be completable with the QR code from the first attempt.
  """
  def prepare_authenticator(socket, proof) do
    secret = Auth.generate_mfa_secret()
    uri = MfaQr.provisioning_uri(socket.assigns.current_user.email, secret)

    socket
    |> assign(:mfa_enrollment_step, :totp)
    |> assign(:mfa_enrollment_proof, proof)
    |> assign(:mfa_secret, secret)
    |> assign(:mfa_uri, uri)
    |> assign(:mfa_qr_svg, MfaQr.svg(uri))
    |> assign(:mfa_error, nil)
  end

  @doc """
  Returns the enrollment to its idle state, clearing the secret and every error.

  The secret is dropped rather than kept for a retry, for the same reason
  `prepare_authenticator/2` mints a new one.
  """
  def reset(socket) do
    socket
    |> assign(:mfa_enrollment_step, :idle)
    |> assign(:mfa_enrollment_proof, nil)
    |> assign(:mfa_enrollment_email_error, nil)
    |> assign(:mfa_secret, nil)
    |> assign(:mfa_uri, nil)
    |> assign(:mfa_qr_svg, nil)
    |> assign(:mfa_error, nil)
  end

  @doc """
  Carries a just-completed enrollment into the live socket's own authority.

  Without this the page keeps rendering from the subject it mounted with, which
  still says the member has no second factor — so a freshly enrolled operator
  would be told to enrol again by the very page that just enrolled them.
  """
  def assign_current_proof(socket, user) do
    subject = %{
      socket.assigns.current_subject
      | actor: user,
        mfa: true,
        mfa_enrollment_verified_at: user.mfa_enabled_at
    }

    auth = %{socket.assigns.current_auth | mfa_enrollment_verified_at: user.mfa_enabled_at}

    socket
    |> assign(:current_subject, subject)
    |> assign(:current_auth, auth)
  end
end
