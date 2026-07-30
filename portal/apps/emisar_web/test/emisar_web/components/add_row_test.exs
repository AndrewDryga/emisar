defmodule EmisarWeb.Components.AddRowTest do
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  test "merges collection spacing with the shared affordance" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.add_row label="Add input" class="mt-6" phx-click="add_input" />
      """)

    assert html =~ "mt-6"
    assert html =~ "border-dashed"
    assert html =~ ~s(phx-click="add_input")
  end
end
