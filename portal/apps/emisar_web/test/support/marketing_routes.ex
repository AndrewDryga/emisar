defmodule EmisarWeb.MarketingRoutes do
  @moduledoc """
  The public marketing surface, derived from the router.

  Two batteries hand-maintain a route list — `@routes` in
  `EmisarWeb.MarketingTest` (render + CSP + indexability) and
  `@indexable_routes` in `EmisarWeb.MarketingStructuralTest` (structural +
  breadcrumbs). Both parity-check themselves against this one derivation, so a
  page added to the router cannot silently skip either battery and the two
  guards cannot drift apart.
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
end
