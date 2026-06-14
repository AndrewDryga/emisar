defmodule EmisarWeb.Components.DangerZoneTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.danger_zone/1` and asserts it builds the
  destructive `<.button variant="danger">` itself — carrying the `data-confirm`
  guard and the caller's `phx-click` — so a detail page declares the action,
  not the button markup. The `data-confirm` dialog is a real safety mechanism
  on disable/delete, so its presence is part of the contract.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EmisarWeb.CoreComponents

  test "renders a danger button carrying the confirm guard and the phx-click" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.danger_zone
        title="Disable this runner"
        confirm="Disable this runner? It cannot reconnect."
        phx-click="disable"
      >
        <:body>Removes it from the catalog.</:body>
        Disable runner
      </CoreComponents.danger_zone>
      """)

    assert html =~ "Disable this runner"
    assert html =~ "Removes it from the catalog."
    assert html =~ "Disable runner"
    # The destructive button is built by the component (danger variant), with
    # the confirm dialog + the action wired through.
    assert html =~ "text-rose-200"
    assert html =~ "data-confirm"
    assert html =~ "Disable this runner? It cannot reconnect."
    assert html =~ ~s(phx-click="disable")
  end
end
