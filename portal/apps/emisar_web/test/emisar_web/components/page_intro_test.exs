defmodule EmisarWeb.Components.PageIntroTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.page_intro/1` — the line under an index
  page's title. Asserts the three slots (subtitle lead, right-aligned actions,
  and a "How this works" help card) and that interpolated text is escaped
  (IL-16: index intros carry no `raw/1`).
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EmisarWeb.CoreComponents

  describe "page_intro/1" do
    test "renders the subtitle as a readable-width lead line" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.page_intro>Each pack has a pinned trusted hash.</CoreComponents.page_intro>
        """)

      assert html =~ "Each pack has a pinned trusted hash."
      assert html =~ "max-w-2xl"
      assert html =~ "text-zinc-400"
    end

    test "actions slot renders alongside the subtitle, right-aligned" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.page_intro>
          Subtitle text
          <:actions><button>Add</button></:actions>
        </CoreComponents.page_intro>
        """)

      assert html =~ "Subtitle text"
      assert html =~ "Add"
      assert html =~ "shrink-0"
    end

    test "help slot renders a 'How this works' card below the subtitle" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.page_intro>
          <:help>Every action has a risk tier from the catalog.</:help>
        </CoreComponents.page_intro>
        """)

      assert html =~ "How this works"
      assert html =~ "Every action has a risk tier from the catalog."
      # The help body rides on the canonical panel/card surface.
      assert html =~ "bg-zinc-950/40"
    end

    test "renders nothing when no slot is given" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.page_intro />
        """)

      refute html =~ "max-w-2xl"
      refute html =~ "How this works"
    end

    test "escapes interpolated subtitle text (no raw HTML injection)" do
      assigns = %{evil: "<script>alert(1)</script>"}

      html =
        rendered_to_string(~H"""
        <CoreComponents.page_intro>{@evil}</CoreComponents.page_intro>
        """)

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
