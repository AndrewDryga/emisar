defmodule EmisarWeb.Components.CodePanelTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.code_panel/1` — the ONE framed code
  surface (design-console-ux §1). Asserts the header contract (label, annotation,
  copy), the `$` prompt, the scroll clamp, and that the code renders escaped
  (IL-16: argv/JSON/snippets carry attacker-influenceable text).
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "code_panel/1" do
    test "renders the section-title label over the mono pre" do
      assigns = %{}

      html =
        rendered_to_string(~H|<CoreComponents.code_panel label="Arguments" code="{}" />|)

      assert html =~ "Arguments"
      # The label is the 16px section-title tier, not a field-key eyebrow —
      # a code artifact's header follows the same grammar as sibling panels.
      assert html =~ "font-display text-base font-semibold"
      assert html =~ "<pre"
      assert html =~ "font-mono"
    end

    test "annotation renders as right-side header meta" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<CoreComponents.code_panel label="Arguments" annotation="sha256:abc…" code="{}" />|
        )

      assert html =~ "sha256:abc…"
      # The annotation cluster shrinks (truncate engages); the label holds its
      # width — a long annotation must never collide with the eyebrow or push
      # the Copy button off-viewport on a phone.
      assert html =~ ~s(class="flex shrink-0 items-center gap-2")
      assert html =~ ~s(class="flex min-w-0 items-center gap-2")
      assert html =~ "truncate font-mono"
    end

    test "copy renders a copy button targeting the pre id" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<CoreComponents.code_panel id="snippet-x" label="Snippet" copy copy_label="Copy snippet" code="a" />|
        )

      assert html =~ ~s(data-copy="#snippet-x")
      assert html =~ "Copy snippet"
    end

    test "prompt renders the select-none shell prefix" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<CoreComponents.code_panel label="Command" prompt code="systemctl restart nginx" />|
        )

      assert html =~ "select-none"
      assert html =~ "$ "
      assert html =~ "systemctl restart nginx"
    end

    test "max_h clamps the pre" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H|<CoreComponents.code_panel label="Payload" max_h="max-h-64" code="{}" />|
        )

      assert html =~ "max-h-64"
    end

    test "the code is HTML-escaped — argv/snippets are attacker-influenceable (IL-16)" do
      assigns = %{evil: "<script>alert(1)</script>"}

      html =
        rendered_to_string(~H|<CoreComponents.code_panel label="Payload" code={@evil} />|)

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end

    test "the scroll region is keyboard-focusable and names itself (UI-006 a11y)" do
      assigns = %{}

      html =
        rendered_to_string(~H|<CoreComponents.code_panel label="Arguments" code="{}" />|)

      # The overflow-auto <pre> takes a tab stop so a keyboard-only operator can
      # scroll to clipped code (axe scrollable-region-focusable); its label names it.
      assert html =~ ~s(tabindex="0")
      assert html =~ ~s(aria-label="Arguments")
    end

    test "a wrapping, unclamped panel is not a dead tab stop (UI-006 a11y)" do
      assigns = %{}

      html =
        rendered_to_string(~H|<CoreComponents.code_panel label="Prompt" wrap code="hi" />|)

      # It wraps and has no height clamp, so it never scrolls — no focus target.
      refute html =~ ~s(tabindex="0")
    end
  end
end
