defmodule EmisarWeb.Components.ChipTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.chip/1` — the small inline label beside a
  row title. Covers the tones, the `mono` variant, and the `upcase` variant
  that absorbed the former `<.tag>` (uppercase-semibold status label), plus
  escaping (IL-16: chips carry attacker-influenced labels like group names).
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EmisarWeb.CoreComponents

  describe "chip/1" do
    test "default tone is a quiet zinc label" do
      assigns = %{}

      html = rendered_to_string(~H"<CoreComponents.chip>group: default</CoreComponents.chip>")

      assert html =~ "group: default"
      assert html =~ "font-medium"
      assert html =~ "bg-zinc-800/80"
      refute html =~ "uppercase"
    end

    test "a colored tone carries its ring" do
      assigns = %{}

      html =
        rendered_to_string(~H"<CoreComponents.chip tone={:rose}>Suspended</CoreComponents.chip>")

      assert html =~ "Suspended"
      assert html =~ "bg-rose-500/15"
      assert html =~ "ring-rose-500/30"
    end

    test "upcase renders the status-tag look (uppercase + semibold)" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H"<CoreComponents.chip upcase tone={:emerald}>Trusted</CoreComponents.chip>"
        )

      assert html =~ "Trusted"
      assert html =~ "uppercase"
      assert html =~ "font-semibold"
      assert html =~ "tracking-wider"
      assert html =~ "bg-brand-500/15"
      refute html =~ "font-medium"
    end

    test "mono renders monospace and class is merged through" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H"<CoreComponents.chip mono class=\"ml-2\">actions:read</CoreComponents.chip>"
        )

      assert html =~ "actions:read"
      assert html =~ "font-mono"
      assert html =~ "ml-2"
    end

    test "escapes interpolated label text (no raw HTML injection)" do
      assigns = %{evil: "<script>alert(1)</script>"}

      html = rendered_to_string(~H"<CoreComponents.chip>{@evil}</CoreComponents.chip>")

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
