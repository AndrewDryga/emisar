defmodule EmisarWeb.Components.MfaEnrollmentTest do
  @moduledoc """
  Renders `EmisarWeb.AuthComponents.mfa_enrollment/1` — the ONE TOTP
  enrollment block (profile voluntary setup + enforced-MFA interstitial).
  Asserts the QR svg, the manual setup key, the shared code input and actions.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.AuthComponents

  defp render_enrollment(assigns) do
    rendered_to_string(~H"""
    <AuthComponents.mfa_enrollment
      qr_svg={@qr_svg}
      setup_key={@setup_key}
      form={@form}
      variant={@variant}
    >
      <:instructions :if={@instructions}>{@instructions}</:instructions>
      <:actions>
        <button phx-disable-with="Verifying...">Confirm and enable</button>
      </:actions>
    </AuthComponents.mfa_enrollment>
    """)
  end

  defp base_assigns do
    %{
      qr_svg: ~s(<svg viewBox="0 0 10 10"><rect /></svg>),
      setup_key: "ABC234",
      form: to_form(%{"otp" => ""}, as: "mfa"),
      variant: :stacked,
      instructions: nil
    }
  end

  defp render_email_verification(assigns) do
    rendered_to_string(~H"""
    <AuthComponents.mfa_enrollment_email_verification
      email={@email}
      form={@form}
      error={@error}
    >
      <:actions><button>Verify email</button></:actions>
    </AuthComponents.mfa_enrollment_email_verification>
    """)
  end

  describe "mfa_enrollment/1" do
    test "shows a copyable manual key beside the QR without a provisioning URI" do
      html = render_enrollment(base_assigns())

      assert html =~ ~s(<svg viewBox="0 0 10 10">)
      assert html =~ "Scan with your authenticator"
      assert html =~ "Can't scan? Enter a setup key"
      assert html =~ ~s(data-copy-text="ABC234")
      assert html =~ "choose a time-based key"
      refute html =~ "otpauth://"
      assert html =~ ~s(id="mfa_form")
      assert html =~ ~s(phx-submit="confirm_mfa")
      assert html =~ ~s(id="mfa-otp")
      assert html =~ "Confirm and enable"
    end

    test "renders page instructions with the shared code form" do
      html =
        base_assigns()
        |> Map.merge(%{variant: :split, instructions: "Scan, then confirm."})
        |> render_enrollment()

      assert html =~ "Scan, then confirm."
    end

    test "no instructions slot → no empty guidance paragraph" do
      html = render_enrollment(base_assigns())

      refute html =~ ~s(class="text-sm text-zinc-300")
    end
  end

  test "recovery acknowledgement requires saving before the final action" do
    assigns = %{saved: false}

    html =
      rendered_to_string(~H"""
      <AuthComponents.recovery_code_acknowledgement saved={@saved} event="dismiss_recovery_codes" />
      """)

    assert html =~ "I&#39;ve saved my recovery codes somewhere safe"
    assert html =~ ~s(phx-click="toggle_codes_saved")
    assert html =~ ~r/<button[^>]*disabled/

    assigns = %{saved: true}

    html =
      rendered_to_string(~H"""
      <AuthComponents.recovery_code_acknowledgement saved={@saved} event="continue" label="Continue" />
      """)

    refute html =~ ~r/<button[^>]*\sdisabled[\s=>]/
    assert html =~ ~s(phx-click="continue")
  end

  test "email verification precedes the QR with an inline code form" do
    html =
      render_email_verification(%{
        email: "owner@example.com",
        form: to_form(%{"code" => ""}, as: "mfa_enrollment"),
        error: "Wrong code"
      })

    assert html =~ "owner@example.com"
    assert html =~ ~s(id="mfa_enrollment_email_form")
    assert html =~ ~s(phx-submit="verify_mfa_enrollment_email")
    assert html =~ ~s(id="mfa-enrollment-email-code")
    assert html =~ "Wrong code"
    assert html =~ "Verify email"
  end
end
