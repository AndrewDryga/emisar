defmodule EmisarWeb.Components.SourceBadgeTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.source_badge/1` and verifies that every
  icon-encoded dispatch source has a hover/focus tooltip and accessible name
  while the adjacent text remains the accountable actor. Source badges are safe
  in responsive slots that render the same component twice because this
  aria-label mode emits no DOM ids.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "source_badge/1" do
    test "explains every source icon" do
      sources = [
        {:mcp, "hero-bolt", "Dispatched via MCP"},
        {:runbook, "hero-book-open", "Dispatched by a runbook"},
        {:scheduled, "hero-clock", "Dispatched by a schedule"},
        {:operator, "hero-user", "Dispatched by an operator"}
      ]

      for {source, icon, tooltip} <- sources do
        assigns = %{source: source, tooltip: tooltip}

        html =
          rendered_to_string(~H"""
          <CoreComponents.source_badge source={@source} label="Maya Chen" />
          """)

        assert html =~ icon
        assert html =~ ~s(aria-label="#{assigns.tooltip}")
        assert html =~ ~s(role="tooltip")
        assert html =~ ~s(title="Maya Chen")
        refute html =~ ~s(aria-describedby=)
      end
    end
  end
end
