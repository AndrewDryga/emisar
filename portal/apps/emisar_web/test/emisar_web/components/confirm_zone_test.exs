defmodule EmisarWeb.Components.ConfirmZoneTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.confirm_zone/1` and asserts it builds the
  action `<.button>` itself — carrying the caller's `phx-click`, and (for the
  danger tone) the `data-confirm` guard — so a detail page declares the action,
  not the button markup. The `data-confirm` dialog is a real safety mechanism on
  disable/delete, so its presence is part of the danger contract; the `:success`
  twin (enable/restore) is the same structure with no confirm.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  test "danger tone (default) builds a danger button carrying the confirm guard and phx-click" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.confirm_zone
        title="Disable this runner"
        confirm="Disable this runner? It cannot reconnect."
        phx-click="disable"
      >
        <:body>Removes it from the catalog.</:body>
        Disable runner
      </CoreComponents.confirm_zone>
      """)

    assert html =~ "Disable this runner"
    assert html =~ "Removes it from the catalog."
    assert html =~ "Disable runner"
    # The destructive button is built by the component (danger/rose), with the
    # confirm dialog + the action wired through.
    assert html =~ "text-rose-200"
    assert html =~ "data-confirm"
    assert html =~ "Disable this runner? It cannot reconnect."
    assert html =~ ~s(phx-click="disable")
  end

  test "success tone is the emerald twin with no confirm dialog (safe restore)" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.confirm_zone tone={:success} title="Enable this runner" phx-click="enable">
        <:body>Clears the disabled flag.</:body>
        Enable runner
      </CoreComponents.confirm_zone>
      """)

    assert html =~ "Enable this runner"
    assert html =~ "Enable runner"
    # Emerald styling, the success button, the action wired through — and NO
    # confirm dialog (enable is a safe restorative action, not a destructive one).
    assert html =~ "text-brand-100"
    assert html =~ ~s(phx-click="enable")
    refute html =~ "data-confirm"
  end
end
