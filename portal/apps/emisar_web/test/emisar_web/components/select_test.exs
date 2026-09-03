defmodule EmisarWeb.Components.SelectTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.select/1` — the per-option select for the
  cases `options_for_select/2` can't express. Asserts the contract: each option
  map's `value`/`label`/`disabled`/`selected` reaches the markup, the optional
  prompt + its `selected`, the label/box association, and that labels are
  HTML-escaped (option text carries account data — IL-16).
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_select(attrs) do
    assigns = %{attrs: attrs}

    rendered_to_string(~H"""
    <CoreComponents.select {@attrs} />
    """)
  end

  describe "select/1" do
    test "renders an <option> per option map with its value and label" do
      html =
        render_select(%{
          name: "target",
          options: [
            %{value: "a", label: "Alpha", disabled: false, selected: false},
            %{value: "b", label: "Beta", disabled: false, selected: false}
          ]
        })

      assert html =~ "<select"
      assert html =~ ~s(name="target")
      assert html =~ ~s(value="a")
      assert html =~ "Alpha"
      assert html =~ ~s(value="b")
      assert html =~ "Beta"
    end

    test "marks the disabled and selected options" do
      html =
        render_select(%{
          name: "tier",
          options: [
            %{value: "allow", label: "Allow", disabled: true, selected: false},
            %{value: "deny", label: "Deny", disabled: false, selected: true}
          ]
        })

      # The disabled option carries `disabled`; the selected one `selected`.
      assert html =~ ~r/<option[^>]*value="allow"[^>]*disabled/s
      assert html =~ ~r/<option[^>]*value="deny"[^>]*selected/s
      # …and not the other way round.
      refute html =~ ~r/<option[^>]*value="deny"[^>]*disabled/s
    end

    test "renders the prompt as a leading empty-value option, selectable" do
      html =
        render_select(%{
          name: "target",
          prompt: "Choose…",
          prompt_selected: true,
          options: [%{value: "a", label: "Alpha", disabled: false, selected: false}]
        })

      assert html =~ ~r/<option value=""[^>]*selected[^>]*>\s*Choose…/s
    end

    test "no prompt option when prompt is unset" do
      html =
        render_select(%{
          name: "target",
          options: [%{value: "a", label: "Alpha", disabled: false, selected: false}]
        })

      refute html =~ ~s(value="")
    end

    test "an optional label renders above the select; absent by default" do
      with_label =
        render_select(%{
          name: "target",
          label: "Apply to",
          options: [%{value: "a", label: "Alpha", disabled: false, selected: false}]
        })

      assert with_label =~ ~s(<label)
      assert with_label =~ "Apply to"

      without_label =
        render_select(%{
          name: "target",
          options: [%{value: "a", label: "Alpha", disabled: false, selected: false}]
        })

      refute without_label =~ ~s(<label)
    end

    test "option labels are HTML-escaped — they carry account data (IL-16)" do
      html =
        render_select(%{
          name: "target",
          options: [
            %{value: "x", label: "<script>alert(1)</script>", disabled: false, selected: false}
          ]
        })

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end

    test "a label is associated with its box, with or without a caller id" do
      # No caller passed an `id`, so `<label for>` matched nothing and the one
      # labelled select shipped a combo box with no accessible name.
      derived =
        render_select(%{
          name: "target",
          label: "Apply to",
          options: [%{value: "a", label: "Alpha", disabled: false, selected: false}]
        })

      assert derived =~ ~s(<label for="input-target")
      assert derived =~ ~s(id="input-target")

      explicit =
        render_select(%{
          id: "policy-target-1",
          name: "target",
          label: "Apply to",
          options: [%{value: "a", label: "Alpha", disabled: false, selected: false}]
        })

      assert explicit =~ ~s(<label for="policy-target-1")
      assert explicit =~ ~s(id="policy-target-1")
    end

    test "an unlabelled select carries no id — its name repeats across editors" do
      html = render_select(%{name: "policy[defaults][low]", options: []})

      refute html =~ ~s(id=)
    end
  end
end
