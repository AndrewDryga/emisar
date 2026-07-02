defmodule EmisarWeb.Components.ButtonTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.button/1` and asserts the polymorphic
  contract — `navigate`/`patch`/`href` render a styled `<.link>` while a
  plain or `phx-click` button stays a `<button>` — plus the variant, size,
  and leading-icon mapping. Visual styling lives in CSS; the rendered tag
  and class hooks are the public contract.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_button(attrs) do
    assigns = %{attrs: attrs}

    rendered_to_string(~H"""
    <CoreComponents.button {@attrs}>Go</CoreComponents.button>
    """)
  end

  describe "button/1" do
    test "a plain button renders a <button> with the primary variant" do
      html = render_button(%{})
      assert html =~ "<button"
      refute html =~ "<a "
      assert html =~ "bg-brand-500"
    end

    test "phx-click stays a <button> — an action, not navigation" do
      html = render_button(%{"phx-click" => "go"})
      assert html =~ "<button"
      assert html =~ ~s(phx-click="go")
      refute html =~ "<a "
    end

    test "navigate renders a styled <.link>, not a <button>" do
      html = render_button(%{navigate: "/app/runbooks/new"})
      assert html =~ "<a "
      assert html =~ ~s(href="/app/runbooks/new")
      # The link carries the same button styling as the <button> branch.
      assert html =~ "bg-brand-500"
      refute html =~ "<button"
    end

    test "href and patch also render a link" do
      assert render_button(%{href: "/x"}) =~ "<a "
      assert render_button(%{patch: "/y"}) =~ "<a "
    end

    test "variant + tone + size + icon are reflected in the markup" do
      html = render_button(%{variant: :secondary, tone: :rose, size: :sm, icon: "hero-trash"})
      assert html =~ "text-rose-200"
      assert html =~ "px-2.5 py-1 text-xs"
      assert html =~ "hero-trash"
    end

    test "nil tone resolves to the variant's natural tone" do
      assert render_button(%{}) =~ "bg-brand-500"
      assert render_button(%{variant: :secondary}) =~ "border-zinc-800"
      assert render_button(%{variant: :ghost}) =~ "text-zinc-300"
    end

    test "the amber primary and the ghost tone ramp" do
      assert render_button(%{tone: :amber}) =~ "bg-amber-500"
      assert render_button(%{variant: :ghost, tone: :rose}) =~ "text-rose-300"
      assert render_button(%{variant: :ghost, tone: :amber}) =~ "text-amber-300"
      assert render_button(%{variant: :ghost, tone: :brand}) =~ "text-brand-300"
    end
  end
end
