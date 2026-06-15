defmodule EmisarWeb.Components.CheckboxTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.checkbox/1` — the standalone (non-form-field)
  checkbox. Asserts the contract: the label text + the standard indigo accent
  and `focus:ring-2` ring, the `checked` flag, name/value + event bindings +
  `disabled` riding the global `:rest`, the opt-in `unchecked_value` companion
  hidden input, a rich inner-block label, and that the label is HTML-escaped
  (it carries account data — IL-16).
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EmisarWeb.CoreComponents

  defp render_checkbox(attrs) do
    assigns = %{attrs: attrs}

    rendered_to_string(~H"""
    <CoreComponents.checkbox {@attrs} />
    """)
  end

  defp render_checkbox_with_block(attrs, inner) do
    assigns = %{attrs: attrs, inner: inner}

    rendered_to_string(~H"""
    <CoreComponents.checkbox {@attrs}>{@inner}</CoreComponents.checkbox>
    """)
  end

  describe "checkbox/1" do
    test "renders the label and the standard indigo accent + focus ring" do
      html = render_checkbox(%{name: "agree", label: "I agree"})

      assert html =~ ~s(type="checkbox")
      assert html =~ ~s(name="agree")
      assert html =~ "I agree"
      assert html =~ "text-indigo-500"
      assert html =~ "focus:ring-2"
    end

    test "reflects the checked flag" do
      assert render_checkbox(%{name: "x", label: "x", checked: true}) =~ "checked"
      refute render_checkbox(%{name: "x", label: "x", checked: false}) =~ "checked"
    end

    test "name/value + event bindings + disabled ride the global rest" do
      html =
        render_checkbox(%{
          :name => "runner_filter[]",
          :value => "r-1",
          :checked => true,
          :disabled => true,
          "phx-click" => "toggle",
          "phx-value-id" => "r-1"
        })

      assert html =~ ~s(name="runner_filter[]")
      assert html =~ ~s(value="r-1")
      assert html =~ "disabled"
      assert html =~ ~s(phx-click="toggle")
      assert html =~ ~s(phx-value-id="r-1")
    end

    test "unchecked_value emits the companion hidden input; absent by default" do
      with_hidden =
        render_checkbox(%{name: "allow", value: "true", unchecked_value: "false", label: "Allow"})

      assert with_hidden =~ ~r/<input[^>]*type="hidden"[^>]*name="allow"[^>]*value="false"/s

      without_hidden = render_checkbox(%{name: "allow", value: "true", label: "Allow"})
      refute without_hidden =~ ~s(type="hidden")
    end

    test "a rich inner-block label overrides the label string" do
      html = render_checkbox_with_block(%{name: "x", label: "ignored"}, "Rich content")

      assert html =~ "Rich content"
      refute html =~ "ignored"
    end

    test "the label is HTML-escaped — it carries account data (IL-16)" do
      html = render_checkbox(%{name: "x", label: "<script>alert(1)</script>"})

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
