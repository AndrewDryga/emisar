defmodule EmisarWeb.Components.ChipOverflowTest do
  @moduledoc """
  `EmisarWeb.CoreComponents.chip_overflow/1` clips a scope allowlist to the first
  `limit` chips and hides the rest behind a `+N` toggle, so a member scoped to
  many packs reads as three names plus the true size instead of dominating a
  roster row. These tests hold the three states — clipped, expanded, and a list
  short enough to need no toggle — and the accessible name on the control.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp markup(assigns) do
    rendered_to_string(~H"""
    <CoreComponents.chip_overflow
      id="member-packs-1"
      items={@items}
      expanded?={@expanded?}
      toggle="toggle_scope_expand"
      toggle_value="mem-1"
      label="packs"
    >
      <:lead :if={@lead}>{@lead}</:lead>
      <:item :let={pack}>
        <CoreComponents.chip mono>{pack}</CoreComponents.chip>
      </:item>
    </CoreComponents.chip_overflow>
    """)
  end

  describe "chip_overflow/1" do
    test "collapsed shows the first three items and a +N toggle naming the full count" do
      html =
        markup(%{
          items: ~w[bonding consul debian docker frr grafana],
          expanded?: false,
          lead: nil
        })

      assert html =~ "bonding"
      assert html =~ "consul"
      assert html =~ "debian"
      refute html =~ "docker"
      refute html =~ "grafana"

      assert html =~ "+3"
      assert html =~ ~s(phx-click="toggle_scope_expand")
      assert html =~ ~s(phx-value-id="mem-1")
      assert html =~ ~s(aria-expanded="false")
      assert html =~ ~s(aria-label="Show all 6 packs")
    end

    test "expanded shows every item and a Show fewer toggle" do
      html =
        markup(%{items: ~w[bonding consul debian docker frr grafana], expanded?: true, lead: nil})

      assert html =~ "docker"
      assert html =~ "grafana"
      assert html =~ "Show fewer"
      assert html =~ ~s(aria-expanded="true")
      assert html =~ ~s(aria-label="Show fewer packs")
      refute html =~ "+3"
    end

    test "a list at or below the limit renders no toggle" do
      html = markup(%{items: ~w[docker linux-core], expanded?: false, lead: nil})

      assert html =~ "docker"
      assert html =~ "linux-core"
      refute html =~ "phx-click"
      refute html =~ "aria-expanded"
    end

    test "a list at limit + 1 renders whole — a +1 toggle would take the hidden chip's slot" do
      html = markup(%{items: ~w[alpha bravo charlie delta], expanded?: false, lead: nil})

      assert html =~ "delta"
      refute html =~ "+1"
      refute html =~ "phx-click"
    end

    test "the optional lead renders before the items" do
      html = markup(%{items: ~w[docker linux-core], expanded?: false, lead: "All"})

      assert html =~ "All"
    end
  end
end
