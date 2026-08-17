defmodule EmisarWeb.Components.SourceBadgeTest do
  @moduledoc """
  Renders `EmisarWeb.DomainComponents.source_badge/1` and verifies that every
  icon-encoded dispatch source has a hover/focus tooltip and accessible name
  while the adjacent text remains the accountable actor. Each responsive slot
  supplies its own id so the shared tooltip can flip at viewport edges.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.DomainComponents

  describe "source_badge/1" do
    test "explains every source icon" do
      sources = [
        {:mcp, "hero-sparkles", "Dispatched via MCP"},
        {:runbook, "hero-book-open", "Dispatched by a runbook"},
        {:operator, "hero-user", "Dispatched by an operator"}
      ]

      for {source, icon, tooltip} <- sources do
        assigns = %{source: source, tooltip: tooltip, id: "source-#{source}"}

        html =
          rendered_to_string(~H"""
          <DomainComponents.source_badge id={@id} source={@source} label="Maya Chen" />
          """)

        assert html =~ icon
        assert html =~ ~s(aria-label="#{assigns.tooltip}")
        assert html =~ ~s(role="tooltip")
        assert html =~ ~s(title="Maya Chen")
        assert html =~ ~s(id="#{assigns.id}")
        assert html =~ ~s(aria-describedby="#{assigns.id}")
        assert html =~ ~s(phx-hook="Tooltip")
      end
    end
  end
end
