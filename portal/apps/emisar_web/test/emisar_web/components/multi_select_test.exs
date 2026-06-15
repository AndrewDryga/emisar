defmodule EmisarWeb.Components.MultiSelectTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.multi_select/1` — the `<.select multiple>`
  wrapper owning the size heuristic + the one standard hint. Asserts the
  contract: it's a multi-select, each option map reaches the markup, selected
  options are marked, the row-count clamp (3–6) drives `size`, the one standard
  "⌘/Ctrl-click to select multiple" hint renders (and `hint?: false` suppresses
  it), and labels are HTML-escaped (they carry account data — IL-16).
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EmisarWeb.CoreComponents

  defp render_multi_select(attrs) do
    assigns = %{attrs: attrs}

    rendered_to_string(~H"""
    <CoreComponents.multi_select {@attrs} />
    """)
  end

  defp options(values) do
    Enum.map(values, &%{value: &1, label: &1, disabled: false, selected: false})
  end

  describe "multi_select/1" do
    test "renders a multi-select with an <option> per option map" do
      html = render_multi_select(%{name: "groups[]", options: options(["a", "b"])})

      assert html =~ ~r/<select[^>]*multiple/s
      assert html =~ ~s(name="groups[]")
      assert html =~ ~s(value="a")
      assert html =~ ~s(value="b")
    end

    test "renders the one standard hint; hint?: false suppresses it" do
      with_hint = render_multi_select(%{name: "g[]", options: options(["a"])})
      assert with_hint =~ "⌘/Ctrl-click to select multiple."

      without_hint = render_multi_select(%{name: "g[]", options: options(["a"]), hint?: false})
      refute without_hint =~ "⌘/Ctrl-click to select multiple."
    end

    test "the size clamp floors at 3 and caps at 6" do
      # One option → floored to 3.
      assert render_multi_select(%{name: "g[]", options: options(["a"])}) =~ ~s(size="3")

      # Four options → exactly 4 (inside the band).
      four = render_multi_select(%{name: "g[]", options: options(["a", "b", "c", "d"])})
      assert four =~ ~s(size="4")

      # Eight options → capped at 6.
      eight = render_multi_select(%{name: "g[]", options: options(~w(a b c d e f g h))})
      assert eight =~ ~s(size="6")
    end

    test "an explicit size overrides the clamp" do
      html = render_multi_select(%{name: "g[]", options: options(["a"]), size: 2})
      assert html =~ ~s(size="2")
    end

    test "marks the selected options" do
      html =
        render_multi_select(%{
          name: "g[]",
          options: [
            %{value: "on", label: "on", disabled: false, selected: true},
            %{value: "off", label: "off", disabled: false, selected: false}
          ]
        })

      assert html =~ ~r/<option(?=[^>]*\bvalue="on")(?=[^>]*\bselected)[^>]*>/
      refute html =~ ~r/<option(?=[^>]*\bvalue="off")(?=[^>]*\bselected)[^>]*>/
    end

    test "option labels are HTML-escaped — they carry account data (IL-16)" do
      html =
        render_multi_select(%{
          name: "g[]",
          options: [
            %{value: "x", label: "<script>alert(1)</script>", disabled: false, selected: false}
          ]
        })

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
