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
        <CoreComponents.event_block icon="identity.credential" title="Key rotated">
          <:body>Swap first, then revoke.</:body>
          <div id="payload">the artifact</div>
        </CoreComponents.event_block>
        """)

      assert html =~ "identity.credential"
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

    test "links only the title when a destination is provided" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.event_block
          icon="state.awaiting_human"
          title="Waiting for approval"
          title_navigate="/app/demo/approvals/request-id"
        >
          <:body>The request covers every action and target runner.</:body>
        </CoreComponents.event_block>
        """)

      document = LazyHTML.from_document(html)
      link = LazyHTML.query(document, ~s(a[href="/app/demo/approvals/request-id"]))
      assert LazyHTML.text(link) =~ "Waiting for approval"
      refute LazyHTML.text(link) =~ "The request covers"
      assert LazyHTML.text(document) =~ "The request covers every action and target runner."
    end

    test "keeps the title as text when no accessible destination is provided" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.event_block
          icon="state.awaiting_human"
          title="Waiting for approval"
          title_navigate={nil}
        >
          <:body>The request covers every action and target runner.</:body>
        </CoreComponents.event_block>
        """)

      assert html =~ "Waiting for approval"
      assert html |> LazyHTML.from_document() |> LazyHTML.query("a") |> Enum.empty?()
    end

    test "rose tone marks a dead outcome (cancelled/errored)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.event_block icon="state.cancelled" tone={:rose} title="Cancelled">
          <:body>approval denied: out of window.</:body>
        </CoreComponents.event_block>
        """)

      assert html =~ "text-rose-400"
      assert html =~ "bg-rose-400/40"
      refute html =~ "text-amber-300"
    end

    test "forwards a stable id to the alert root" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.event_block id="runner-alert" icon="state.online" title="Offline">
          <:body>No runner is connected.</:body>
        </CoreComponents.event_block>
        """)

      assert html =~ ~s(id="runner-alert")
    end

    test "compact size uses the supporting text tier" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.event_block icon="security.posture_warning" size={:compact} title="Review">
          <:body>Supporting guidance.</:body>
        </CoreComponents.event_block>
        """)

      assert html =~ "text-xs"
      refute html =~ "text-sm"
    end

    test "rejects an unregistered icon instead of rendering a spine without a glyph" do
      assigns = %{}

      assert_raise ArgumentError, ~r/unknown icon/, fn ->
        rendered_to_string(~H"""
        <CoreComponents.event_block icon="" title="Offline">
          <:body>No runner is connected.</:body>
        </CoreComponents.event_block>
        """)
      end
    end
  end
end
