defmodule EmisarWeb.Components.SearchableSelectTest do
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  test "keeps the trigger concise while rendering grouped searchable metadata" do
    assigns = %{
      groups: [
        %{
          label: "caddy",
          options: [
            %{
              value: "caddy|caddy.reload_config",
              label: "caddy.reload_config",
              description: "Reload configuration · caddy",
              search: "caddy.reload_config reload configuration caddy",
              disabled: false
            },
            %{
              value: "caddy|caddy.missing",
              label: "caddy.missing",
              description: "Unavailable saved action",
              search: "caddy.missing unavailable",
              disabled: true
            }
          ]
        }
      ]
    }

    html =
      rendered_to_string(~H"""
      <CoreComponents.searchable_select
        id="action-picker"
        name="action"
        value="caddy|caddy.reload_config"
        selected_label="caddy.reload_config"
        groups={@groups}
        aria_label="Action"
      />
      """)

    assert html =~ ~s(phx-hook="Combobox")
    assert html =~ ~s(name="action")
    assert html =~ ~s(aria-label="Action")
    assert html =~ ">caddy.reload_config<"
    assert html =~ ~s(data-description="Reload configuration · caddy")
    assert html =~ ~s(data-search="caddy.reload_config reload configuration caddy")
    assert html =~ ~s(aria-selected)
    assert html =~ ~s(disabled)
  end
end
