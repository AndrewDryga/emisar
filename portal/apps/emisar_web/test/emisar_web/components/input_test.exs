defmodule EmisarWeb.Components.InputTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.input/1` — asserts the `size` variant
  contract: `:default` is the comfortable field every caller renders, while
  `:compact` tightens padding/margin for a dense grid (the runbook editor's
  arg rows) across the text/select/textarea branches.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EmisarWeb.CoreComponents

  defp render_input(attrs) do
    assigns = %{attrs: attrs}

    rendered_to_string(~H"""
    <CoreComponents.input {@attrs} />
    """)
  end

  describe "input/1 size variant" do
    test "defaults to the comfortable box metrics" do
      html = render_input(%{name: "key", value: ""})

      assert html =~ "px-3 py-2.5"
      assert html =~ "mt-2"
    end

    test "compact tightens padding + label gap on a text input" do
      html = render_input(%{name: "key", value: "", size: :compact})

      assert html =~ "px-2 py-1.5"
      assert html =~ "mt-1"
      refute html =~ "px-3 py-2.5"
    end

    test "compact applies to the select branch" do
      html =
        render_input(%{
          name: "kind",
          type: "select",
          value: "group",
          size: :compact,
          options: [{"group", "group"}]
        })

      assert html =~ "<select"
      assert html =~ "px-2 py-1.5"
    end

    test "compact applies to the textarea branch" do
      html = render_input(%{name: "description", value: "", type: "textarea", size: :compact})

      assert html =~ "<textarea"
      assert html =~ "px-2 py-1.5"
    end
  end
end
