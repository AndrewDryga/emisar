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
    assert html =~ ">caddy.reload_config<"
    assert html =~ ~s(data-description="Reload configuration · caddy")
    assert html =~ ~s(data-search="caddy.reload_config reload configuration caddy")
    assert html =~ ~s(disabled)
  end

  test "tells assistive tech what it is, whether it is open, and which option is chosen" do
    assigns = %{
      groups: [
        %{
          label: "caddy",
          options: [
            %{value: "caddy|reload", label: "caddy.reload_config", search: "reload"},
            %{value: "caddy|validate", label: "caddy.validate_config", search: "validate"}
          ]
        }
      ]
    }

    document =
      rendered_to_string(~H"""
      <CoreComponents.searchable_select
        id="action-picker"
        name="action"
        value="caddy|reload"
        selected_label="caddy.reload_config"
        groups={@groups}
        aria_label="Action"
      />
      """)
      |> LazyHTML.from_fragment()

    # The face shows only the value, so the name says the field too; the hook
    # flips aria-expanded on the trigger as it opens the panel it controls.
    assert present?(
             document,
             ~s(button[data-combobox-trigger][aria-label="Action, caddy.reload_config"]) <>
               ~s([aria-expanded="false"][aria-controls="action-picker-panel"])
           )

    assert present?(document, "#action-picker-panel[data-combobox-panel]")
    assert present?(document, ~s(input[data-combobox-search][aria-label="Search Action"]))

    # Option buttons have no selected state; the chosen one is aria-current.
    assert present?(document, ~s(button[data-value="caddy|reload"][aria-current="true"]))
    refute present?(document, ~s(button[data-value="caddy|validate"][aria-current]))
    refute present?(document, "[aria-selected]")
  end

  defp present?(document, selector),
    do: not (document |> LazyHTML.query(selector) |> Enum.empty?())
end
