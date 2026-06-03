defmodule EmisarWeb.CopyButtonTest do
  @moduledoc """
  Regression coverage for the `<.copy_button>` component.

  Historically every Copy button in the portal was silently broken in
  prod because they used inline `onclick="..."` handlers, which CSP
  strips. The fix is a delegated `[data-copy]` listener in app.js plus
  this single component that every site uses. These tests pin the
  contract so a future copy/paste of an inline `onclick` button can be
  caught instead of waiting for a user to report "Copy doesn't work."
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  test "renders data-copy with a target selector, no inline onclick" do
    assigns = %{target: "#install-cmd"}

    html =
      rendered_to_string(~H"""
      <EmisarWeb.CoreComponents.copy_button target={@target}>Copy</EmisarWeb.CoreComponents.copy_button>
      """)

    assert html =~ ~s(data-copy="#install-cmd")
    refute html =~ "onclick"
  end

  test "renders data-copy-text with a literal string" do
    assigns = %{text: "emk-abc-xyz"}

    html =
      rendered_to_string(~H"""
      <EmisarWeb.CoreComponents.copy_button text={@text}>Copy key</EmisarWeb.CoreComponents.copy_button>
      """)

    assert html =~ ~s(data-copy-text="emk-abc-xyz")
    refute html =~ "onclick"
  end

  test "renders a custom Copied label via :label_copied" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <EmisarWeb.CoreComponents.copy_button target="#x" label_copied="Copied!">
        Copy
      </EmisarWeb.CoreComponents.copy_button>
      """)

    assert html =~ ~s(data-copy-label-copied="Copied!")
  end

  test "rest passes through id, class merges, no onclick anywhere" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <EmisarWeb.CoreComponents.copy_button id="my-btn" target="#t" class="my-class">
        Copy
      </EmisarWeb.CoreComponents.copy_button>
      """)

    assert html =~ ~s(id="my-btn")
    assert html =~ "my-class"
    refute html =~ "onclick"
  end
end
