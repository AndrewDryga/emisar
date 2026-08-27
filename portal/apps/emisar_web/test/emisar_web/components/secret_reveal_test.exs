defmodule EmisarWeb.Components.SecretRevealTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.secret_reveal/1` — the reveal-once grid
  for recovery CODES (its only job since the single-secret holdouts moved to
  the naked `event_block` + `code_panel` grammar). Asserts the per-code copy
  cells, Copy all, Download .txt, and the `:actions` slot.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "secret_reveal/1" do
    test "codes grid: per-code copy cells, Copy all, Download .txt, actions slot" do
      assigns = %{codes: ["aaaa2222bbbb3333", "cccc4444dddd5555"]}

      html =
        rendered_to_string(~H"""
        <CoreComponents.secret_reveal
          id="mfa-recovery-codes"
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
      assert html =~ "Save your recovery codes"
      assert html =~ ~s(data-copy-text="aaaa2222bbbb3333")
      assert html =~ ~s(data-copy-text="cccc4444dddd5555")
      assert html =~ ~s(data-copy-text="aaaa2222bbbb3333\ncccc4444dddd5555")
      assert html =~ "Copy all"
      assert html =~ ~s(download="emisar-recovery-codes.txt")
      assert html =~ "aaaa2222bbbb3333%0Acccc4444dddd5555"
      assert html =~ "I've saved them"
    end

    test "without download_name the .txt offer is absent" do
      assigns = %{codes: ["aaaa2222bbbb3333"]}

      html =
        rendered_to_string(~H"""
        <CoreComponents.secret_reveal title="Save your recovery codes" codes={@codes}>
          Each code works once.
        </CoreComponents.secret_reveal>
        """)

      assert html =~ "Copy all"
      refute html =~ "Download .txt"
    end
  end
end
