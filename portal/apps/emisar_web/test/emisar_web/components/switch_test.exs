defmodule EmisarWeb.Components.SwitchTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.switch/1` — the ONE enforcement toggle
  (team MFA + SSO). Asserts the two-state contract: solid brand + off_label
  while OFF (the enabling action), rose outline + on_label while ON, correct
  aria-checked, and passthrough of phx-click / data-confirm.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_switch(assigns) do
    rendered_to_string(~H"""
    <CoreComponents.switch
      on={@on}
      on_label="Stop enforcing MFA"
      off_label="Enforce MFA"
      phx-click="toggle_require_mfa"
      aria-label="Enforce MFA account-wide"
      data-confirm="Sure?"
    />
    """)
  end

  describe "switch/1" do
    test "OFF renders the enabling action — bordered neutral + off_label" do
      html = render_switch(%{on: false})

      assert html =~ ~s(aria-checked="false")
      # A settings toggle is not the page's primary — never a brand fill.
      assert html =~ "border-zinc-800"
      refute html =~ "bg-brand-500"
      assert html =~ "Enforce MFA"
      refute html =~ "Stop enforcing MFA"
    end

    test "ON renders the disabling action — rose outline + on_label" do
      html = render_switch(%{on: true})

      assert html =~ ~s(aria-checked="true")
      assert html =~ "border-rose-500/40"
      assert html =~ "Stop enforcing MFA"
      refute html =~ "bg-brand-500"
    end

    test "role, click, and confirm ride through" do
      html = render_switch(%{on: false})

      assert html =~ ~s(role="switch")
      assert html =~ ~s(phx-click="toggle_require_mfa")
      assert html =~ ~s(data-confirm="Sure?")
      assert html =~ ~s(aria-label="Enforce MFA account-wide")
    end
  end
end
