defmodule EmisarWeb.Components.SegmentedFilterTest do
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_group do
    assigns = %{}

    rendered_to_string(~H"""
    <CoreComponents.segmented_filter_group label="Time window">
      <CoreComponents.segmented_filter active?={true} phx-click="preset" phx-value-window="1h">
        Last hour
      </CoreComponents.segmented_filter>
      <CoreComponents.segmented_filter active?={false} phx-click="preset" phx-value-window="24h">
        Last 24 hours
      </CoreComponents.segmented_filter>
    </CoreComponents.segmented_filter_group>
    """)
  end

  describe "segmented_filter_group/1 and segmented_filter/1" do
    test "joins one filter dimension under an accessible group" do
      html = render_group()

      assert html =~ ~s(role="group")
      assert html =~ ~s(aria-label="Time window")
      assert html =~ "inline-flex rounded-md ring-1 ring-zinc-800"
      refute html =~ "gap-"
    end

    test "renders shared edges, compact chip density, pressed state, and LiveView bindings" do
      html = render_group()

      assert html =~ "px-2 py-1"
      refute html =~ "min-h-10"
      refute html =~ "px-3 py-2"
      assert html =~ "first:rounded-l-md"
      assert html =~ "last:rounded-r-md"
      assert html =~ "first:border-l-0"
      assert html =~ ~s(aria-pressed="true")
      assert html =~ ~s(aria-pressed="false")
      assert html =~ ~s(phx-click="preset")
      assert html =~ ~s(phx-value-window="1h")
      assert html =~ "bg-brand-500/10"
      assert html =~ "bg-zinc-900"
    end
  end
end
