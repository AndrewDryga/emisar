defmodule EmisarWeb.Components.MfaEnrollmentTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.mfa_enrollment/1` — the ONE TOTP
  enrollment block (profile voluntary setup + enforced-MFA interstitial).
  Asserts the QR svg, the can't-scan URI disclosure, the shared
  `code_input` confirm form, the slots, and the stacked/split wrappers.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_enrollment(assigns) do
    rendered_to_string(~H"""
    <CoreComponents.mfa_enrollment
      qr_svg={@qr_svg}
      uri={@uri}
      form={@form}
      variant={@variant}
    >
      <:instructions :if={@instructions}>{@instructions}</:instructions>
      <:actions>
        <button phx-disable-with="Verifying...">Confirm and enable</button>
      </:actions>
    </CoreComponents.mfa_enrollment>
    """)
  end

  defp base_assigns do
    %{
      qr_svg: ~s(<svg viewBox="0 0 10 10"><rect /></svg>),
      uri: "otpauth://totp/emisar:op@example.com?secret=ABC234",
      form: to_form(%{"otp" => ""}, as: "mfa"),
      variant: :stacked,
      instructions: nil
    }
  end

  describe "mfa_enrollment/1" do
    test "stacked: QR svg, caption, URI disclosure with copy, code_input form" do
      html = render_enrollment(base_assigns())

      assert html =~ ~s(<svg viewBox="0 0 10 10">)
      assert html =~ "Scan with your authenticator"
      assert html =~ "Can't scan? Use a setup URI"
      assert html =~ "otpauth://totp/emisar:op@example.com?secret=ABC234"
      assert html =~ ~s(data-copy="#mfa-uri")
      assert html =~ ~s(id="mfa_form")
      assert html =~ ~s(phx-submit="confirm_mfa")
      assert html =~ ~s(id="mfa-otp")
      assert html =~ "Confirm and enable"
      assert html =~ "space-y-4"
      refute html =~ "sm:grid-cols-[auto_1fr]"
    end

    test "split: the 2-col grid wrapper and the instructions slot render" do
      html =
        base_assigns()
        |> Map.merge(%{variant: :split, instructions: "Scan, then confirm."})
        |> render_enrollment()

      assert html =~ "sm:grid-cols-[auto_1fr]"
      assert html =~ "Scan, then confirm."
    end

    test "no instructions slot → no empty guidance paragraph" do
      html = render_enrollment(base_assigns())

      refute html =~ ~s(class="text-sm text-zinc-300")
    end
  end
end
