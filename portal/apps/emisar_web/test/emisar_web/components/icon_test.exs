defmodule EmisarWeb.Components.IconTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.icon/1` and asserts the optical-rendering
  contract: the size read from the call site's `h-*` class picks the grid
  bucket, and the small buckets project the same master through a slightly
  zoomed viewBox so on-screen weight and presence stay constant instead of
  thinning as the box shrinks (the founder's correction). The stroke numbers
  themselves live in `assets/css/app.css`; what the markup must carry is the
  bucket and the projection.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_icon(class) do
    assigns = %{class: class}

    rendered_to_string(~H"""
    <CoreComponents.icon name="product.runner" class={@class} />
    """)
  end

  test "a 16px call site renders the zoomed 16 bucket" do
    html = render_icon("h-4 w-4")

    assert html =~ ~s(data-icon-grid="16")
    assert html =~ ~s(viewBox="1.2 1.2 21.6 21.6")
  end

  test "chip-sized icons stay in the 16 bucket" do
    assert render_icon("h-3.5 w-3.5") =~ ~s(data-icon-grid="16")
    assert render_icon("h-3 w-3") =~ ~s(viewBox="1.2 1.2 21.6 21.6")
  end

  test "a 20px call site renders the zoomed 20 bucket" do
    html = render_icon("h-5 w-5")

    assert html =~ ~s(data-icon-grid="20")
    assert html =~ ~s(viewBox="0.6 0.6 22.8 22.8")
  end

  test "24px and above render the full grid unzoomed" do
    assert render_icon("h-6 w-6") =~ ~s(viewBox="0 0 24 24")
    assert render_icon("h-10 w-10") =~ ~s(data-icon-grid="24")
  end

  test "no size class falls back to the full grid" do
    assert render_icon(nil) =~ ~s(viewBox="0 0 24 24")
  end
end
