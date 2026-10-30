defmodule EmisarWeb.MarketingRoutes do
  @moduledoc """
  The public marketing surface, derived from the router.

  Both page batteries — `EmisarWeb.MarketingTest` (render + CSP +
  indexability) and `EmisarWeb.MarketingStructuralTest` (structural +
  breadcrumbs) — parametrize directly over `battery_paths/0`, so a page added
  to the router joins both automatically and there is no hand-maintained
  inventory left to drift.
  """

  # MarketingController GET routes that are NOT indexable HTML pages (feeds),
  # so they sit outside both batteries on purpose.
  @non_html_routes ~w(/changelog.xml)

  @doc """
  Every static public marketing HTML path in the router.

  Dynamic `:slug` families are excluded — each battery pins its own concrete
  representative (e.g. `/guides/how-emisar-works`) instead.
  """
  def static_html_paths do
    EmisarWeb.Router.__routes__()
    |> Enum.filter(&(&1.verb == :get and &1.plug == EmisarWeb.MarketingController))
    |> Enum.map(& &1.path)
    |> Enum.reject(&(String.contains?(&1, ":") or &1 in @non_html_routes))
    |> MapSet.new()
  end

  # One concrete representative per dynamic `:slug` family, so the batteries
  # still render one of each even though the derivation excludes them.
  @dynamic_representatives ~w(
    /packs/postgres
    /packs/cassandra
    /guides/how-emisar-works
    /guides/give-ai-agents-safe-production-access
    /guides/prompt-injection-for-ops-teams
  )

  @doc """
  The battery surface: every static public HTML path plus the pinned dynamic
  representatives, sorted — what the page batteries parametrize over.
  """
  def battery_paths do
    static_html_paths()
    |> Enum.concat(@dynamic_representatives)
    |> Enum.sort()
  end
end
