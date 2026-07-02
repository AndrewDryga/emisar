defmodule EmisarWeb.Components.DropdownTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.dropdown/1` and `menu_item/1` and asserts
  their contract — the click-to-open shell is a native `<details>` with the
  default disclosure marker hidden, `menu_item` tones mirror the ghost button
  tones, the action attrs ride the global `:rest`, and labels are escaped.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_dropdown(attrs, trigger, inner) do
    assigns = %{attrs: attrs, trigger: trigger, inner: inner}

    rendered_to_string(~H"""
    <CoreComponents.dropdown {@attrs}>
      <:trigger>{@trigger}</:trigger>
      {@inner}
    </CoreComponents.dropdown>
    """)
  end

  defp render_menu_item(attrs, label) do
    assigns = %{attrs: attrs, label: label}

    rendered_to_string(~H"""
    <CoreComponents.menu_item {@attrs}>{@label}</CoreComponents.menu_item>
    """)
  end

  describe "dropdown/1" do
    test "is a native <details> shell — opens/closes with no JS" do
      html = render_dropdown(%{}, "Actions", "panel body")

      assert html =~ "<details"
      assert html =~ "<summary"
      # The `group` class lets trigger/panel markup use group-open: modifiers.
      assert html =~ "group"
    end

    test "renders the trigger in the summary and the inner block in the panel" do
      html = render_dropdown(%{}, "Open menu", "the items")

      assert html =~ "Open menu"
      assert html =~ "the items"
    end

    test "hides the default <summary> disclosure marker (WebKit + standard)" do
      html = render_dropdown(%{}, "Actions", "x")

      assert html =~ "list-none"
      # The `&` in the Tailwind arbitrary-variant selector is HTML-escaped to
      # `&amp;` in the attribute value — the browser unescapes it back.
      assert html =~ "[&amp;::-webkit-details-marker]:hidden"
      assert html =~ "[&amp;::marker]:hidden"
    end

    test "align anchors the panel — right by default, left and stretch on request" do
      assert render_dropdown(%{}, "t", "p") =~ "right-0"
      assert render_dropdown(%{align: :left}, "t", "p") =~ "left-0"
      assert render_dropdown(%{align: :stretch}, "t", "p") =~ "top-full"
    end

    test "summary_class and panel_class skin the trigger and panel per site" do
      html =
        render_dropdown(
          %{summary_class: "ring-1 ring-zinc-800", panel_class: "z-30 w-56 shadow-2xl"},
          "t",
          "p"
        )

      assert html =~ "ring-1 ring-zinc-800"
      assert html =~ "z-30 w-56 shadow-2xl"
    end
  end

  describe "menu_item/1" do
    test "renders a left-aligned full-width button row by default" do
      html = render_menu_item(%{}, "Edit name")

      assert html =~ "<button"
      assert html =~ "w-full"
      assert html =~ "text-left"
      assert html =~ "Edit name"
    end

    test "tones mirror the ghost button vocabulary (zinc/amber/rose/emerald)" do
      assert render_menu_item(%{}, "Edit") =~ "text-zinc-300"
      assert render_menu_item(%{tone: :amber}, "Suspend") =~ "text-amber-300"
      assert render_menu_item(%{tone: :rose}, "Remove") =~ "text-rose-300"
      assert render_menu_item(%{tone: :brand}, "Restore") =~ "text-brand-300"
    end

    test "a leading icon renders before the label" do
      html = render_menu_item(%{icon: "hero-plus"}, "Add")

      assert html =~ "hero-plus"
    end

    test "phx-click / phx-value-* / data-confirm ride the global rest" do
      html =
        render_menu_item(
          %{
            "phx-click" => "suspend",
            "phx-value-membership_id" => "m-1",
            "data-confirm" => "Suspend this member?"
          },
          "Suspend access"
        )

      assert html =~ ~s(phx-click="suspend")
      assert html =~ ~s(phx-value-membership_id="m-1")
      assert html =~ ~s(data-confirm="Suspend this member?")
    end

    test "navigate renders a <.link>, not a <button>, so a menu row can navigate" do
      html = render_menu_item(%{navigate: "/onboarding"}, "Create workspace")

      assert html =~ "<a"
      assert html =~ ~s(href="/onboarding")
      refute html =~ "<button"
    end

    test "the label is HTML-escaped (IL-16 — labels can carry account/user names)" do
      html = render_menu_item(%{}, "<script>alert(1)</script>")

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
