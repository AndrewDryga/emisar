defmodule EmisarWeb.Components.NavBadgeTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.nav_link/1` with various badge
  inputs and asserts the pill is shown / hidden / capped as documented.
  The visual styling itself isn't asserted — that lives in CSS — but
  the badge text and presence are part of the public contract.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EmisarWeb.CoreComponents

  defp render_link(badge) do
    assigns = %{badge: badge}

    rendered_to_string(~H"""
    <CoreComponents.nav_link to="/app/approvals" active={false} icon="hero-shield-check" badge={@badge}>
      Approvals
    </CoreComponents.nav_link>
    """)
  end

  defp badge_text(html) do
    case Regex.run(~r/bg-amber-500\/20[^>]*>\s*([^<\s][^<]*?)\s*</, html) do
      [_, text] -> text
      nil -> nil
    end
  end

  describe "nav_link badge" do
    test "zero is hidden (no badge)" do
      refute render_link(0) =~ "bg-amber-500/20"
    end

    test "nil is hidden (no badge)" do
      refute render_link(nil) =~ "bg-amber-500/20"
    end

    test "negative numbers are treated as no badge" do
      refute render_link(-3) =~ "bg-amber-500/20"
    end

    test "1 renders the count verbatim" do
      assert badge_text(render_link(1)) == "1"
    end

    test "an exact number under 100 renders verbatim" do
      assert badge_text(render_link(42)) == "42"
    end

    test "exactly 100 collapses to 99+ so the pill never overflows the rail" do
      assert badge_text(render_link(100)) == "99+"
    end

    test "values well above 100 collapse to 99+" do
      assert badge_text(render_link(1_234)) == "99+"
    end
  end
end
