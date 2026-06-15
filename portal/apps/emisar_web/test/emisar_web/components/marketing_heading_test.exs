defmodule EmisarWeb.Components.MarketingHeadingTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.marketing_heading/1` — the marketing
  type scale — and asserts that `tag` controls the semantic level (so pages
  keep their existing, SEO-load-bearing `<h1>`/`<h2>` hierarchy) while
  `scale` controls only the visual size. The size ramp is the contract.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EmisarWeb.CoreComponents

  defp render_heading(attrs) do
    assigns = %{attrs: attrs}

    rendered_to_string(~H"""
    <CoreComponents.marketing_heading {@attrs}>Title</CoreComponents.marketing_heading>
    """)
  end

  describe "marketing_heading/1" do
    test "tag sets the semantic level — the size class never changes the tag" do
      assert render_heading(%{tag: "h1", scale: :hero}) =~ "<h1"
      assert render_heading(%{tag: "h2", scale: :hero}) =~ "<h2"
      assert render_heading(%{tag: "h3", scale: :hero}) =~ "<h3"
    end

    test "each scale maps to one documented size ramp" do
      assert render_heading(%{tag: "h1", scale: :display}) =~ "text-6xl md:text-7xl"
      assert render_heading(%{tag: "h1", scale: :hero}) =~ "text-4xl md:text-5xl"
      assert render_heading(%{tag: "h2", scale: :section}) =~ "text-4xl sm:text-5xl"
    end

    test "extra class composes alongside the scale (e.g. the mt-2 under an eyebrow)" do
      html = render_heading(%{tag: "h1", scale: :hero, class: "mt-2"})
      assert html =~ "mt-2"
      assert html =~ "text-4xl md:text-5xl"
    end
  end
end
