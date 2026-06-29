defmodule EmisarWeb.Components.IconButtonTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.icon_button/1` and asserts its contract —
  the required `label` becomes BOTH `aria-label` and `title` (an icon-only
  control is never nameless), the tone maps to a hover class, and event
  bindings + `disabled` pass through the global `:rest`.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_icon_button(attrs) do
    assigns = %{attrs: attrs}

    rendered_to_string(~H"""
    <CoreComponents.icon_button {@attrs} />
    """)
  end

  describe "icon_button/1" do
    test "label becomes both aria-label and title — never a nameless icon" do
      html = render_icon_button(%{icon: "hero-x-mark", label: "Close"})

      assert html =~ "<button"
      assert html =~ ~s(aria-label="Close")
      assert html =~ ~s(title="Close")
    end

    test "neutral is the default tone; danger maps to the rose hover" do
      assert render_icon_button(%{icon: "hero-trash", label: "Remove"}) =~ "hover:text-zinc-200"

      assert render_icon_button(%{icon: "hero-trash", label: "Remove", tone: "danger"}) =~
               "hover:text-rose-300"
    end

    test "disabled + event bindings ride the global rest" do
      html =
        render_icon_button(%{
          :icon => "hero-arrow-up",
          :label => "Move up",
          :disabled => true,
          "phx-click" => "move_step",
          "phx-value-dir" => "up"
        })

      assert html =~ "disabled"
      assert html =~ ~s(phx-click="move_step")
      assert html =~ ~s(phx-value-dir="up")
    end
  end
end
