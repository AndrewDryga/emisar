defmodule EmisarWeb.Components.IconTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.icon/1` and asserts the optical-rendering
  contract: the size read from the call site's `h-*` class picks the grid
  bucket; a native 16-grid compact renders 1:1 (the pixel-crisp path), and a
  24-grid master in a small bucket projects through the zoomed viewBox so
  presence stays constant. Stroke numbers live in `assets/css/app.css`; what
  the markup must carry is the bucket, the unit, and the projection.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_icon(name, class) do
    assigns = %{name: name, class: class}

    rendered_to_string(~H"""
    <CoreComponents.icon name={@name} class={@class} />
    """)
  end

  test "a 16px call site renders a native compact 1:1" do
    html = render_icon("product.runner", "h-4 w-4")

    assert html =~ ~s(data-icon-grid="16")
    assert html =~ ~s(data-icon-unit="16")
    assert html =~ ~s(viewBox="0 0 16 16")
  end

  test "chip-sized icons stay on the native compact" do
    assert render_icon("product.runner", "h-3.5 w-3.5") =~ ~s(viewBox="0 0 16 16")
    assert render_icon("product.runner", "h-3 w-3") =~ ~s(data-icon-unit="16")
  end

  test "a 24-grid master in the 16 bucket projects through the zoomed viewBox" do
    # state.selected keeps a 24-grid compact (its check is a mask cut), so the
    # small bucket compensates with the zoom instead of a native cut.
    html = render_icon("state.selected", "h-4 w-4")

    assert html =~ ~s(data-icon-unit="24")
    assert html =~ ~s(viewBox="1.2 1.2 21.6 21.6")
  end

  test "a 20px call site renders the zoomed 20 bucket" do
    html = render_icon("product.runner", "h-5 w-5")

    assert html =~ ~s(data-icon-grid="20")
    assert html =~ ~s(viewBox="0.6 0.6 22.8 22.8")
  end

  test "24px and above render the full grid unzoomed" do
    assert render_icon("product.runner", "h-6 w-6") =~ ~s(viewBox="0 0 24 24")
    assert render_icon("product.runner", "h-10 w-10") =~ ~s(data-icon-grid="24")
  end

  test "no size class falls back to the full grid" do
    assert render_icon("product.runner", nil) =~ ~s(viewBox="0 0 24 24")
  end
end
