defmodule EmisarWeb.MarketingHTML do
  @moduledoc """
  Templates for the public marketing site.

  See the `marketing_html` directory for all templates available.
  """
  use EmisarWeb, :html

  embed_templates "marketing_html/*"

  # Hero icon for an action row in the pack-detail action list. `exec`
  # = lightning (runs a binary), `script` = code-bracket (packaged shell
  # script). Defaults to cube for any future kinds.
  def action_icon("exec"), do: "hero-bolt"
  def action_icon("script"), do: "hero-code-bracket"
  def action_icon(_), do: "hero-cube"
end
