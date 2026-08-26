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
        <CoreComponents.tooltip text="Repeated CSV export is on the Team plan">
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
      assert html =~ "Repeated CSV export is on the Team plan"

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

    test "a command rides the shared copyable row inside the described bubble" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.tooltip
          id="runner-version-7"
          text="Runner v0.19.0 is available. Run the command on this host."
          command="sudo emisar update"
        >
          <span>icon</span>
        </CoreComponents.tooltip>
        """)

      bubble = html |> LazyHTML.from_fragment() |> LazyHTML.query_by_id("runner-version-7")

      # The description AT reads carries the reason AND the command it ends in.
      assert LazyHTML.text(bubble) =~ "Run the command on this host."
      assert LazyHTML.text(bubble) =~ "sudo emisar update"

      # It is the shared code_line row — mono, clipped to one line, never a
      # scrolling panel — wired to the delegated clipboard listener, which is
      # what lets Copy work on a control that exists only once revealed.
      assert html =~ ~s(id="runner-version-7-command")
      assert html =~ "font-mono"
      assert html =~ "overflow-hidden text-ellipsis whitespace-nowrap"
      assert html =~ ~s(data-copy-text="sudo emisar update")
      refute html =~ "overflow-x-auto"
    end

    test "a tip with no command is unchanged — prose only, no copy control" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.tooltip text="Role is managed by directory sync">
          <span>Operator</span>
        </CoreComponents.tooltip>
        """)

      assert html =~ "Role is managed by directory sync"
      refute html =~ "data-copy-text"
      refute html =~ "font-mono"
      refute html =~ "-command"
    end

    test "a command keeps its bubble described even on an icon-only trigger" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.tooltip
          text="Run the command on this host."
          command="sudo emisar update"
          aria_label="Runner update available"
        >
          <span aria-hidden="true">icon</span>
        </CoreComponents.tooltip>
        """)

      # An icon-only trigger normally skips ids entirely; a command may not,
      # because the bubble is the only place that command appears.
      assert [_, tooltip_id] = Regex.run(~r/aria-describedby="([^"]+)"/, html)
      bubble = html |> LazyHTML.from_fragment() |> LazyHTML.query_by_id(tooltip_id)
      assert LazyHTML.text(bubble) =~ "sudo emisar update"
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
      assert html =~ ~s(data-side="below")
      refute html =~ "bottom-full mb-2"
    end

    test "declares its side for the flip, and ships a hover bridge for each" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.tooltip text="Issuing an enrollment key needs access to every runner">
          <span>New key</span>
        </CoreComponents.tooltip>
        """)

      # overlay.js reads the declared side once, then rewrites `data-side` when
      # that side has no room — which is what turns the default upward bubble on
      # a page-header control into a downward one instead of a bubble cut off by
      # the top of the screen.
      assert html =~ ~s(data-side="above")

      # Both bridges ship, keyed to the side, so the pointer can still cross the
      # gap from trigger to bubble after a flip (WCAG 1.4.13 hoverable).
      assert html =~ "data-[side=above]:before:top-full"
      assert html =~ "data-[side=below]:before:bottom-full"
    end

    test "alignment left opens the bubble inward from a left-edge trigger" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.tooltip text="Minimum runner version" align={:left}>
          <span>unsupported</span>
        </CoreComponents.tooltip>
        """)

      assert html =~ "left-0"
      refute html =~ "right-0"
    end

    test "responsive alignment follows a status chip that moves between layouts" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.tooltip text="Minimum runner version" align={:responsive}>
          <span>unsupported</span>
        </CoreComponents.tooltip>
        """)

      assert html =~ "right-0 sm:left-0 sm:right-auto"
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
