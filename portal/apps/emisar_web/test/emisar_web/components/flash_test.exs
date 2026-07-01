defmodule EmisarWeb.Components.FlashTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.flash/1` — the top-right alert. Asserts that a
  transient flash carries the auto-close hook + a tone-tinted countdown bar (and
  that errors linger a beat longer), that the state-driven connection flashes opt
  OUT of auto-close, and that the message is escaped (IL-16: flashes carry
  interpolated, attacker-influenceable text like runner names).
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "flash/1" do
    test "a transient info flash carries the auto-close hook and a brand countdown bar" do
      assigns = %{}

      html =
        rendered_to_string(~H"<CoreComponents.flash kind={:info}>Saved.</CoreComponents.flash>")

      assert html =~ "Saved."
      assert html =~ ~s(phx-hook="FlashAutoClose")
      assert html =~ ~s(data-close-ms="5000")
      # the subtle bottom bar, tinted to the info tone, clipped by overflow-hidden
      assert html =~ "data-flash-bar"
      assert html =~ "bg-brand-400/70"
      assert html =~ "overflow-hidden"
    end

    test "a transient error flash reads a beat longer and tints the bar rose" do
      assigns = %{}

      html =
        rendered_to_string(~H"<CoreComponents.flash kind={:error}>Nope.</CoreComponents.flash>")

      assert html =~ ~s(data-close-ms="7000")
      assert html =~ "bg-rose-400/70"
      assert html =~ ~s(phx-hook="FlashAutoClose")
    end

    test "auto_close={false} renders no bar and no auto-close hook (state-driven flashes)" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H"<CoreComponents.flash kind={:error} auto_close={false}>Reconnecting</CoreComponents.flash>"
        )

      refute html =~ "FlashAutoClose"
      refute html =~ "data-flash-bar"
      refute html =~ "data-close-ms"
    end

    test "escapes interpolated message text (IL-16)" do
      assigns = %{evil: "<script>alert(1)</script>"}

      html =
        rendered_to_string(~H"<CoreComponents.flash kind={:info}>{@evil}</CoreComponents.flash>")

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
