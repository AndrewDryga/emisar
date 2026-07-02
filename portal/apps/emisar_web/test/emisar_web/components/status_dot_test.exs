defmodule EmisarWeb.Components.StatusDotTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.status_dot/1` — the ONE colored dot every
  live-state indicator composes (summary stats, status badges, connection
  dots, audit outcome dots, wait-room pings). Asserts the tone ramp, sizes,
  the pulse/ping animations, and attribute passthrough.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "status_dot/1" do
    test "neutral small dot is the default" do
      assigns = %{}

      html = rendered_to_string(~H"<CoreComponents.status_dot />")

      assert html =~ "bg-zinc-600"
      assert html =~ "h-1.5 w-1.5"
      assert html =~ ~s(aria-hidden="true")
      refute html =~ "animate-"
    end

    test "tones map to the house hue ramp" do
      assigns = %{}

      assert rendered_to_string(~H"<CoreComponents.status_dot tone={:brand} />") =~ "bg-brand-400"
      assert rendered_to_string(~H"<CoreComponents.status_dot tone={:amber} />") =~ "bg-amber-400"
      assert rendered_to_string(~H"<CoreComponents.status_dot tone={:rose} />") =~ "bg-rose-400"
    end

    test "sizes scale the circle" do
      assigns = %{}

      assert rendered_to_string(~H"<CoreComponents.status_dot size={:md} />") =~ "h-2 w-2"
      assert rendered_to_string(~H"<CoreComponents.status_dot size={:lg} />") =~ "h-2.5 w-2.5"
    end

    test "pulse fades in place; ping radiates a live ring" do
      assigns = %{}

      pulse = rendered_to_string(~H"<CoreComponents.status_dot tone={:amber} pulse />")
      assert pulse =~ "animate-pulse"
      refute pulse =~ "animate-ping"

      ping = rendered_to_string(~H"<CoreComponents.status_dot tone={:brand} ping />")
      assert ping =~ "animate-ping"
      assert ping =~ "relative flex"
    end

    test "extra attributes ride through (title tooltip)" do
      assigns = %{}

      html =
        rendered_to_string(~H|<CoreComponents.status_dot tone={:brand} title="Connected" />|)

      assert html =~ ~s(title="Connected")
    end
  end
end
