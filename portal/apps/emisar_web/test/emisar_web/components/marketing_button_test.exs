defmodule EmisarWeb.Components.MarketingButtonTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.marketing_button/1` — the single CTA
  button the marketing site routes every "Start free"/"Talk to sales"-style
  link through — and asserts the polymorphic contract (`href`/`navigate`
  render a `<.link>`, `external` adds the safe-rel pair, a plain one stays a
  `<button>`) plus the variant/size/icon class hooks. Styling lives in the
  class string; the rendered tag + class hooks are the public contract.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_button(attrs) do
    assigns = %{attrs: attrs}

    rendered_to_string(~H"""
    <CoreComponents.marketing_button {@attrs}>Start free</CoreComponents.marketing_button>
    """)
  end

  describe "marketing_button/1" do
    test "a plain button renders a <button> with the primary fill" do
      html = render_button(%{})
      assert html =~ "<button"
      refute html =~ "<a "
      assert html =~ "bg-brand-500"
    end

    test "href and navigate render a styled <.link>, not a <button>" do
      assert render_button(%{href: "/sign_up"}) =~ ~s(href="/sign_up")
      assert render_button(%{navigate: "/docs"}) =~ "<a "
      refute render_button(%{href: "/sign_up"}) =~ "<button"
    end

    test "external opens a new, isolated tab (the noopener/noreferrer pair)" do
      html = render_button(%{external: true, href: "https://github.com/x"})
      assert html =~ ~s(target="_blank")
      assert html =~ ~s(rel="noopener noreferrer")
    end

    test "secondary is the outlined ring variant, not the brand fill" do
      html = render_button(%{variant: :secondary, href: "/x"})
      assert html =~ "ring-1 ring-zinc-800"
      refute html =~ "bg-brand-500"
    end

    test "size maps to the documented padding ramp" do
      assert render_button(%{size: :sm}) =~ "px-4 py-2"
      assert render_button(%{size: :md}) =~ "px-5 py-2.5"
      assert render_button(%{size: :lg}) =~ "px-6 py-3"
    end

    test "block is full-width; a trailing icon renders" do
      assert render_button(%{block: true}) =~ "w-full"
      assert render_button(%{icon: "hero-arrow-right"}) =~ "hero-arrow-right"
    end
  end
end
