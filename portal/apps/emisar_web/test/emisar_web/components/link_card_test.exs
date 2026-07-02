defmodule EmisarWeb.Components.LinkCardTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.link_card/1` — the ONE bordered
  navigation card (install wizard + dashboard onboarding). Asserts the
  href-vs-navigate split: external gets a new tab + outward arrow, in-app
  keeps the right arrow.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "link_card/1" do
    test "href renders an external card — new tab, noopener, outward arrow" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.link_card href="/docs/quickstart" icon="hero-book-open" title="Installation guide">
          Image-bake, cloud-init, manual install.
        </CoreComponents.link_card>
        """)

      assert html =~ ~s(target="_blank")
      assert html =~ ~s(rel="noopener noreferrer")
      assert html =~ "hero-arrow-top-right-on-square"
      assert html =~ "Installation guide"
      assert html =~ "Image-bake, cloud-init, manual install."
    end

    test "navigate renders an in-app card with the right arrow" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.link_card navigate="/packs" icon="hero-cube-transparent" title="Pack registry">
          Browse the catalog.
        </CoreComponents.link_card>
        """)

      assert html =~ ~s(href="/packs")
      refute html =~ ~s(target="_blank")
      assert html =~ "hero-arrow-right"
      refute html =~ "hero-arrow-top-right-on-square"
    end
  end
end
