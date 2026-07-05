defmodule EmisarWeb.Components.EventBlockTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.event_block/1` — the transient event
  block (design-system §8.1): an amber icon capping a quiet spine that binds
  title + body + payload into one contained unit on a page whose main content
  is something else (the agents rotation reveal is the template).
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "event_block/1" do
    test "renders the icon-capped spine, title, body, and payload" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.event_block icon="hero-key" title="Key rotated">
          <:body>Swap first, then revoke.</:body>
          <div id="payload">the artifact</div>
        </CoreComponents.event_block>
        """)

      assert html =~ "hero-key"
      assert html =~ "text-amber-300"
      # the spine: the icon's hue faded back, starting below the icon
      assert html =~ "bg-amber-300/40"
      assert html =~ "Key rotated"
      assert html =~ "Swap first, then revoke."
      assert html =~ ~s(id="payload")
      # containment comes from the spine, never a wash box
      refute html =~ "ring-amber"
      refute html =~ "bg-amber-500/10"
    end

    test "rose tone marks a dead outcome (cancelled/errored)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.event_block icon="hero-no-symbol" tone={:rose} title="Cancelled">
          <:body>approval denied: out of window.</:body>
        </CoreComponents.event_block>
        """)

      assert html =~ "text-rose-400"
      assert html =~ "bg-rose-400/40"
      refute html =~ "text-amber-300"
    end
  end
end
