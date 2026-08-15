defmodule EmisarWeb.Components.RiskPillTest do
  @moduledoc """
  `EmisarWeb.DomainComponents.risk_pill/1` prints one word — HIGH, CRITICAL —
  that an approver has to act on, so the severity lexicon behind it is
  load-bearing copy, not a hint. These tests hold it to the WCAG 1.4.13 shape:
  a focusable trigger and `aria-describedby` to a `role="tooltip"` bubble, so a
  tap, a Tab, or a screen reader all reach the wording a raw `title` hid from
  every one of them.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.DomainComponents

  describe "risk_pill/1" do
    test "the severity lexicon reaches touch and keyboard, not hover alone" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DomainComponents.risk_pill id="approval-42-risk" risk="high" />
        """)

      assert html =~ "high"
      assert html =~ ~s(role="tooltip")
      assert html =~ ~s(tabindex="0")
      assert html =~ "group-focus-within/tooltip:opacity-100"
      assert html =~ ~s(aria-describedby="approval-42-risk")
      assert html =~ ~s(id="approval-42-risk")
      assert html =~ "High — service-affecting"
      refute html =~ "title="
    end

    test "an Ecto.Enum atom carries the same lexicon as a manifest string" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DomainComponents.risk_pill id="run-risk" risk={:critical} />
        """)

      assert html =~ "critical"
      assert html =~ "Critical — data loss or irreversible"
    end

    test "two same-risk pills keep distinct bubble ids" do
      # The whole reason the component takes an id: approvals, packs, and plans
      # all render this pill per row, and a shared bubble id is a duplicate DOM
      # id under a phx-hook.
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DomainComponents.risk_pill id="row-1-risk" risk="high" />
        <DomainComponents.risk_pill id="row-2-risk" risk="high" />
        """)

      assert html =~ ~s(aria-describedby="row-1-risk")
      assert html =~ ~s(aria-describedby="row-2-risk")
    end

    test "the track form takes the fixed width; the inline default is content-sized" do
      # The shared width belongs to a COLUMN of peers, not to the pill (§7.41):
      # baking the track into the component ballooned HIGH on every meta line.
      assigns = %{}

      track =
        rendered_to_string(~H"""
        <DomainComponents.risk_pill id="runner-action-risk" risk="high" variant={:track} />
        """)

      inline =
        rendered_to_string(~H"""
        <DomainComponents.risk_pill id="pending-risk" risk="high" />
        """)

      assert track =~ "w-[5.25rem]"
      assert track =~ "text-center"
      assert track =~ "text-xs"

      refute inline =~ "w-[5.25rem]"
      refute inline =~ "text-center"
      # <.chip upcase> metrics — the house size for a tag riding a line of text.
      assert inline =~ "text-[10px]"
      assert inline =~ "px-1.5"
    end

    test "a stored risk with no lexicon entry renders the bare pill" do
      # A frozen plan can carry a tier we have no wording for. An empty bubble
      # and a stray tab stop are worse than no tooltip at all.
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DomainComponents.risk_pill risk="unheard-of" />
        """)

      assert html =~ "unheard-of"
      refute html =~ ~s(role="tooltip")
      refute html =~ ~s(tabindex="0")
    end
  end
end
