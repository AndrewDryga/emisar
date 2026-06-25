defmodule EmisarWeb.Components.PanelTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.card/1` and `panel/1` and asserts the
  canonical elevated surface (gradient + shadow, `p-5` default) and the panel header
  contract — one heading size, optional subtitle + right-aligned actions, and
  no header chrome when none are given. The class hooks are the public contract.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EmisarWeb.CoreComponents

  defp render_card(attrs) do
    assigns = %{attrs: attrs}

    rendered_to_string(~H"""
    <CoreComponents.card {@attrs}>body</CoreComponents.card>
    """)
  end

  describe "card/1" do
    test "renders the canonical surface with the default p-5 density" do
      html = render_card(%{})
      assert html =~ "rounded-xl border border-zinc-800 bg-zinc-900/30"
      # Console card is the flat hairline tier — no marketing glass lift.
      refute html =~ "shadow"
      assert html =~ "p-5"
      assert html =~ "body"
    end

    test "padding + class are applied" do
      html = render_card(%{padding: "p-6", class: "flex-1"})
      assert html =~ "p-6"
      assert html =~ "flex-1"
      refute html =~ "p-5"
    end
  end

  describe "panel/1" do
    test "wraps the canonical card surface" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.panel title="Default policy">rules</CoreComponents.panel>
        """)

      assert html =~ "bg-zinc-900/30"
      assert html =~ "rules"
    end

    test "title renders one canonical heading; subtitle + actions slot in" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.panel title="Security">
          <:subtitle>When enforced, members without 2FA are funneled.</:subtitle>
          <:actions><button>Enforce</button></:actions>
          body
        </CoreComponents.panel>
        """)

      assert html =~
               ~s(class="font-display text-sm font-semibold tracking-[-0.01em] text-zinc-100")

      assert html =~ "Security"
      assert html =~ "When enforced"
      assert html =~ "Enforce"
      assert html =~ "body"
    end

    test "global attrs (id, …) pass through to the surface element" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.panel id="create-panel" class="hidden" title="X">body</CoreComponents.panel>
        """)

      assert html =~ ~s(id="create-panel")
      assert html =~ "hidden"
    end

    test "no title/subtitle/actions → no header chrome, just the body" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.panel>bare body</CoreComponents.panel>
        """)

      refute html =~ "<header"
      refute html =~ "<h2"
      assert html =~ "bare body"
    end
  end
end
