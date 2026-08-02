defmodule EmisarWeb.Components.DocsScreenshotTest do
  @moduledoc """
  Renders `EmisarWeb.DocsComponents.docs_screenshot/1` and pins its keyboard
  contract: the fullscreen trigger is a real button (never the old hidden
  checkbox + label pair, which no keyboard could operate) and the overlay is a
  labelled dialog with a focusable close control. The open/close/Escape/focus
  behavior lives in docs_lightbox.js and is verified in the browser — these
  assertions pin the data-* wiring that script binds to.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.DocsComponents

  describe "docs_screenshot/1" do
    test "the trigger is a real button wired to its own overlay" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DocsComponents.docs_screenshot
          src="/images/docs/runners.png"
          alt="The runners list"
          title="Console — Runners"
        />
        """)

      # A keyboard-operable trigger, not a CSS checkbox hack.
      refute html =~ "checkbox"
      refute html =~ "<label"
      [trigger] = Regex.run(~r/<button[^>]*data-lightbox-open[^>]*>/, html)
      assert trigger =~ ~s(type="button")
      assert trigger =~ ~s(data-lightbox-open="lb-runners")
      assert trigger =~ ~s(aria-haspopup="dialog")
      assert trigger =~ ~s(aria-controls="lb-runners")
    end

    test "the overlay is a labelled modal dialog with a focusable close control" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DocsComponents.docs_screenshot
          src="/images/docs/runners.png"
          alt="The runners list"
          title="Console — Runners"
        />
        """)

      [dialog] = Regex.run(~r/<div[^>]*data-lightbox[\s>][^>]*>/, html)
      assert dialog =~ ~s(id="lb-runners")
      assert dialog =~ ~s(role="dialog")
      assert dialog =~ ~s(aria-modal="true")
      assert dialog =~ ~s(aria-label="Console — Runners")
      # Hidden until docs_lightbox.js opens it.
      assert dialog =~ "hidden"

      [close] = Regex.run(~r/<button[^>]*data-lightbox-close[^>]*>/, html)
      assert close =~ ~s(type="button")
      assert close =~ ~s(aria-label="Close screenshot")
    end
  end
end
