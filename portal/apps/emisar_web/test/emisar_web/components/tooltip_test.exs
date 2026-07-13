defmodule EmisarWeb.Components.TooltipTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.tooltip/1` — the dark bubble carrying the
  "why" a control is locked/limited. The copy is load-bearing, so the tests
  assert it is reachable on touch AND keyboard, not hover alone: the trigger is
  focusable, the reveal fires on `focus-within`, and `aria-describedby` links it
  to the `role="tooltip"` bubble so assistive tech announces the reason
  (WCAG 1.4.13).
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "tooltip/1" do
    test "the trigger is focusable and describes itself via the role=tooltip bubble" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.tooltip text="CSV export is on the Team plan — upgrade to turn it on">
          <span>Export CSV</span>
        </CoreComponents.tooltip>
        """)

      # Focusable trigger — touch tap and keyboard Tab can both reach it.
      assert html =~ ~s(tabindex="0")
      # The bubble opens on focus, not hover alone.
      assert html =~ "group-focus-within/tooltip:opacity-100"
      assert html =~ ~s(role="tooltip")

      # aria-describedby points at the bubble's id, so AT reads the reason.
      [_, tooltip_id] = Regex.run(~r/aria-describedby="([^"]+)"/, html)
      assert html =~ ~s(id="#{tooltip_id}")
      assert html =~ "CSV export is on the Team plan — upgrade to turn it on"

      # aria-label is gone — the description carries the copy without shadowing
      # the trigger's own name.
      refute html =~ "aria-label"
    end

    test "an explicit id keeps bubble ids unique when the same tip repeats" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.tooltip id="role-lock-42" text="Role is managed by directory sync">
          <span>Operator</span>
        </CoreComponents.tooltip>
        """)

      assert html =~ ~s(id="role-lock-42")
      assert html =~ ~s(aria-describedby="role-lock-42")
    end

    test "an icon-only trigger can carry an accessible name" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.tooltip text="Dispatched via MCP" aria_label="Dispatched via MCP">
          <span aria-hidden="true">icon</span>
        </CoreComponents.tooltip>
        """)

      assert html =~ ~s(aria-label="Dispatched via MCP")
      assert html =~ ~s(role="tooltip")
    end

    test "placement bottom opens the bubble downward" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.tooltip text="Audit export is on the Team plan" placement={:bottom}>
          <span>Export CSV</span>
        </CoreComponents.tooltip>
        """)

      assert html =~ "top-full mt-2"
      refute html =~ "bottom-full mb-2"
    end

    test "escapes interpolated tip text (no raw HTML injection)" do
      assigns = %{evil: "<script>alert(1)</script>"}

      html =
        rendered_to_string(~H"""
        <CoreComponents.tooltip text={@evil}>
          <span>trigger</span>
        </CoreComponents.tooltip>
        """)

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
