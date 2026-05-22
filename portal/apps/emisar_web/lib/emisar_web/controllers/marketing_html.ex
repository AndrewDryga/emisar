defmodule EmisarWeb.MarketingHTML do
  @moduledoc """
  Templates for the public marketing site.

  See the `marketing_html` directory for all templates available.
  """
  use EmisarWeb, :html

  embed_templates "marketing_html/*"
end
