defmodule EmisarWeb.Components.ConfirmZoneTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.confirm_zone/1` and asserts it builds the
  action `<.button>` itself — so a detail page declares the action, not the
  button markup. A destructive action (`on_confirm`) fires behind OUR styled
  modal, NEVER a native `data-confirm`; the `:success` twin (enable/restore) is
  the same row with a direct `phx-click` and no modal.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  test "danger tone fires behind our modal — a rose button + a plain confirm_dialog, never data-confirm" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.confirm_zone
        id="disable-runner"
        title="Disable this runner"
        confirm="It cannot reconnect until you enable it again."
        confirm_label="Disable runner"
        on_confirm={Phoenix.LiveView.JS.push("disable")}
      >
        <:body>Removes it from the catalog.</:body>
        Disable runner
      </CoreComponents.confirm_zone>
      """)

    assert html =~ "Disable this runner"
    assert html =~ "Removes it from the catalog."
    assert html =~ "Disable runner"
    # Canvas row: neutral title, the danger carried by the ROSE button (not a
    # tinted frame). The confirmation is OUR modal (its body copy renders), never
    # the native browser dialog.
    assert html =~ "text-zinc-100"
    assert html =~ "text-rose-200"
    refute html =~ "data-confirm"
    assert html =~ "It cannot reconnect until you enable it again."
    # The trigger OPENS the dialog (a JS show targeting the dialog id), and the
    # real "disable" event lives on the dialog's Confirm.
    document = LazyHTML.from_fragment(html)

    [trigger | _] = document |> LazyHTML.query("button[phx-click]") |> Enum.to_list()
    assert trigger |> LazyHTML.text() |> String.trim() == "Disable runner"

    assert Enum.any?(js_ops(trigger), fn [kind, args] ->
             kind == "show" and args["to"] == "#disable-runner"
           end)

    confirm = LazyHTML.query(document, "#disable-runner-confirm")

    assert Enum.any?(js_ops(confirm), fn [kind, args] ->
             kind == "push" and args["event"] == "disable"
           end)
  end

  defp js_ops(node) do
    [click] = LazyHTML.attribute(node, "phx-click")
    Jason.decode!(click)
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
    # Neutral title + the emerald PRIMARY button (a filled "do this" for the
    # restore), the action wired through — and NO confirm dialog (enable is a
    # safe restorative action, not a destructive one).
    assert html =~ "text-zinc-100"
    assert html =~ "bg-brand-500"
    assert html =~ ~s(phx-click="enable")
    refute html =~ "data-confirm"
  end
end
