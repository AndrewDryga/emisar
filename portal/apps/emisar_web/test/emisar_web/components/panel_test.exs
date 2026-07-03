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
      # The ISLAND surface: a zinc-900 step lifted off the black ground by a
      # low-opacity white ring + inset top highlight (no gray hairline border).
      assert html =~ "rounded-xl bg-zinc-900/60"
      assert html =~ "ring-white/[0.07]"
      # Elevation comes from the surface step + a 1px INSET top highlight —
      # never a drop shadow (unreadable on the black ground) or marketing glass.
      assert html =~ "shadow-[inset_0_1px_0_0_rgba(255,255,255,0.05)]"
      refute html =~ "shadow-lg"
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

      assert html =~ "bg-zinc-900/60"
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
               ~s(class="font-display text-base font-semibold tracking-[-0.012em] text-zinc-100")

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

    test ":split renders the bordered header row over an unpadded body" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.panel variant={:split} title="Recent runs">
          <:actions><a href="/runs">View all</a></:actions>
          <ul>rows</ul>
        </CoreComponents.panel>
        """)

      # The header hairline is line-as-light inside the lit island.
      # Middle-strength separator: solid zinc-800 read too heavy, 8%-white was
      # invisible — /70 is the landed compromise.
      assert html =~ "border-b border-zinc-800/70 px-5 py-3"
      assert html =~ "overflow-hidden"
      assert html =~ "View all"
      refute html =~ ~s(class="rounded-xl border border-zinc-800 bg-zinc-900/30 p-5")
    end

    test "title_variant={:eyebrow} renders the uppercase content label" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.panel title="Reason" title_variant={:eyebrow}>prose</CoreComponents.panel>
        """)

      assert html =~ "uppercase tracking-wider text-zinc-400"
      assert html =~ "Reason"
    end

    test ":badge slots after the title; :annotation is the quiet right-side meta" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.panel variant={:split} title="Decisions">
          <:badge><span data-badge>3</span></:badge>
          <:annotation>2 of 3 approvals</:annotation>
          list
        </CoreComponents.panel>
        """)

      assert html =~ "data-badge"
      assert html =~ "2 of 3 approvals"
    end
  end
end
