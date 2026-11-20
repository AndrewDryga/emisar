defmodule EmisarWeb.MarketingRoutes do
  @moduledoc """
  The public marketing surface, derived from the router.

  Both page batteries — `EmisarWeb.MarketingTest` (render + CSP +
  indexability) and `EmisarWeb.MarketingStructuralTest` (structural +
  breadcrumbs) — parametrize directly over `battery_paths/0`. A static page
  added to the router and a guide added to the controller join both
  automatically; only the `/packs/:id` family keeps pinned examples.
  """

  # MarketingController GET routes that are NOT indexable HTML pages (feeds),
  # so they sit outside both batteries on purpose.
  @non_html_routes ~w(/changelog.xml)

  @doc """
  Every static public marketing HTML path in the router.

  Dynamic `:slug` families are excluded — `battery_paths/0` adds every guide
  from `EmisarWeb.MarketingController.guide_paths/0` and pins pack examples.
  """
  def static_html_paths do
    EmisarWeb.Router.__routes__()
    |> Enum.filter(&(&1.verb == :get and &1.plug == EmisarWeb.MarketingController))
    |> Enum.map(& &1.path)
    |> Enum.reject(&(String.contains?(&1, ":") or &1 in @non_html_routes))
    |> MapSet.new()
  end

  # Pinned pack pages, so the batteries still render the `/packs/:id` family
  # even though the router derivation excludes it.
  @pack_representatives ~w(/packs/postgres /packs/cassandra)

  @doc """
  The battery surface, sorted: every static public HTML path, every guide
  derived from `EmisarWeb.MarketingController.guide_paths/0`, and the pinned
  pack representatives — what the page batteries parametrize over.
  """
  def battery_paths do
    static_html_paths()
    |> Enum.concat(EmisarWeb.MarketingController.guide_paths())
    |> Enum.concat(@pack_representatives)
    |> Enum.sort()
  end
end
