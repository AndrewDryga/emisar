defmodule EmisarWeb.Components.CheckboxListTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.checkbox_list/1` — the flat multi-pick
  that replaced the native `<select multiple>`. Asserts the contract: one
  visible checkbox row per option map, checked/disabled marks, the same
  `name[]` POST semantics, and HTML-escaped labels (they carry account
  data — IL-16).
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_checkbox_list(attrs) do
    assigns = %{attrs: attrs}

    rendered_to_string(~H"""
    <CoreComponents.checkbox_list {@attrs} />
    """)
  end

  defp option(value, overrides \\ %{}) do
    Map.merge(%{value: value, label: value, disabled: false, selected: false}, overrides)
  end

  describe "checkbox_list/1" do
    test "renders one checkbox per option under the shared name" do
      html =
        render_checkbox_list(%{
          name: "selector_values[]",
          options: [option("dba"), option("web")]
        })

      assert html =~ ~s(type="checkbox")
      assert html =~ ~s(name="selector_values[]")
      assert html =~ ~s(value="dba")
      assert html =~ ~s(value="web")
      refute html =~ "<select"
    end

    test "selected and disabled options carry their marks" do
      html =
        render_checkbox_list(%{
          name: "g[]",
          options: [option("picked", %{selected: true}), option("locked", %{disabled: true})]
        })

      assert html =~ ~r/value="picked"[^>]*checked/s or html =~ ~r/checked[^>]*value="picked"/s
      assert html =~ ~r/value="locked"[^>]*disabled/s or html =~ ~r/disabled[^>]*value="locked"/s
      assert html =~ "cursor-not-allowed"
    end

    test "labels are HTML-escaped" do
      html = render_checkbox_list(%{name: "g[]", options: [option("<script>alert(1)</script>")]})

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
