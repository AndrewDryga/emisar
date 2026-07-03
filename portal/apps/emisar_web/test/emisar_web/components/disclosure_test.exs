defmodule EmisarWeb.Components.DisclosureTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.disclosure/1` — the ONE `<details>`
  disclosure (console-ux §6/§7.6). Asserts the summary/body contract, the
  chevron affordance, both sizes, and the server-owned `open` state.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "disclosure/1" do
    test "renders summary + bordered body with the chevron affordance" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.disclosure>
          <:summary>Can't scan? Use a setup URI</:summary>
          the uri
        </CoreComponents.disclosure>
        """)

      assert html =~ "<details"
      assert html =~ "Can't scan? Use a setup URI"
      assert html =~ "the uri"
      assert html =~ "hero-chevron-down"
      assert html =~ "group-open/disc:rotate-180"
      # The body divider is line-as-light inside the lit island surface.
      assert html =~ "border-t border-white/[0.08]"
      refute html =~ ~s( open)
    end

    test "open renders the details expanded (server-owned state, console-ux §7.6)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.disclosure open={true}>
          <:summary>Key scope</:summary>
          picker
        </CoreComponents.disclosure>
        """)

      assert html =~ ~s(open)
    end

    test "sizes scale the summary and body density" do
      assigns = %{}

      sm =
        rendered_to_string(~H"""
        <CoreComponents.disclosure><:summary>s</:summary>b</CoreComponents.disclosure>
        """)

      assert sm =~ "px-3 py-2 text-xs"

      md =
        rendered_to_string(~H"""
        <CoreComponents.disclosure size={:md}><:summary>s</:summary>b</CoreComponents.disclosure>
        """)

      assert md =~ "px-4 py-3 text-sm"
    end
  end
end
