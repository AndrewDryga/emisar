defmodule EmisarWeb.Components.SecretRevealTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.secret_reveal/1` — the ONE reveal-once
  amber box (runner keys, SIEM tokens, SCIM bearers, MFA recovery codes).
  Asserts the single-secret banner (copy target, dismiss X, install slot)
  and the codes card (per-code copy cells, Copy all, Download .txt,
  `:actions` slot, no X without `on_dismiss`).
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "secret_reveal/1" do
    test "banner mode: title, secret with its copy target, dismiss X" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.secret_reveal
          title="Copy this auth key now."
          secret="emk-abc123"
          on_dismiss="dismiss_secret"
        >
          Treat it like a password.
          <:install_command label="Install on a host">
            curl -sSL https://emisar.dev/install.sh | sudo bash
          </:install_command>
        </CoreComponents.secret_reveal>
        """)

      assert html =~ ~s(id="reveal-secret")
      assert html =~ ~s(id="reveal-secret-secret")
      assert html =~ ~s(data-copy="#reveal-secret-secret")
      assert html =~ "emk-abc123"
      assert html =~ ~s(phx-click="dismiss_secret")
      assert html =~ "Install on a host"
      assert html =~ ~s(data-copy="#reveal-secret-install-0")
      assert html =~ "p-6"
    end

    test "codes card: per-code copy cells, Copy all, Download .txt, actions slot" do
      assigns = %{codes: ["aaaa2222bbbb3333", "cccc4444dddd5555"]}

      html =
        rendered_to_string(~H"""
        <CoreComponents.secret_reveal
          id="mfa-recovery-codes"
          variant={:card}
          title="Save your recovery codes"
          codes={@codes}
          download_name="emisar-recovery-codes.txt"
        >
          Each code works once.
          <:actions>
            <button phx-click="dismiss_recovery_codes">I've saved them</button>
          </:actions>
        </CoreComponents.secret_reveal>
        """)

      assert html =~ ~s(id="mfa-recovery-codes")
      assert html =~ ~s(data-copy-text="aaaa2222bbbb3333")
      assert html =~ ~s(data-copy-text="cccc4444dddd5555")
      assert html =~ ~s(data-copy-text="aaaa2222bbbb3333\ncccc4444dddd5555")
      assert html =~ "Copy all"
      assert html =~ ~s(download="emisar-recovery-codes.txt")
      assert html =~ "aaaa2222bbbb3333%0Acccc4444dddd5555"
      assert html =~ "I've saved them"
      # No on_dismiss → no X button.
      refute html =~ ~s(aria-label="Dismiss")
      assert html =~ "p-4"
    end

    test "a card secret without codes renders the single-secret box only" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.secret_reveal
          id="scim-token-p1"
          variant={:card}
          title="Copy this SCIM token now — it's shown only once."
          secret="ems-token"
          on_dismiss="dismiss_scim_token"
        >
          Didn't copy it? Rotate token mints a fresh one.
        </CoreComponents.secret_reveal>
        """)

      assert html =~ ~s(id="scim-token-p1-secret")
      assert html =~ ~s(data-copy="#scim-token-p1-secret")
      refute html =~ "Copy all"
      refute html =~ "Download .txt"
    end
  end
end
