defmodule EmisarWeb.Components.SearchableSelectTest do
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  test "opens on the side that fits, and the fused seam follows it" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <CoreComponents.searchable_select
        id="action-picker"
        name="action"
        selected_label="Choose an action"
        groups={[]}
        aria_label="Action"
      />
      """)

    # The panel ships declaring the side its markup put it on; overlay.js reads
    # that, flips it above the trigger when a picker low on the page has no room
    # below, and stamps the side it landed on back here.
    assert html =~ ~s(data-side="below")

    # The field and its panel fuse into one element, so the squared corners and
    # the dropped border ride the side rather than being baked in downward —
    # both halves ship, and the flip picks one.
    assert html =~ "data-[side=below]:rounded-b-lg data-[side=below]:border-t-0"
    assert html =~ "data-[side=above]:rounded-t-lg data-[side=above]:border-b-0"
  end

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
