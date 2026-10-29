defmodule EmisarWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use EmisarWeb, :controller` and
  `use EmisarWeb, :live_view`.
  """
  use EmisarWeb, :html

  embed_templates "layouts/*"

  attr :json_ld, :string, required: true
  attr :nonce, :string, default: nil

  # Every controller that sets @json_ld encodes it with
  # `Jason.encode!(..., escape: :html_safe)`, which escapes <, >, &, and /, so
  # the payload cannot close this script element.
  # sobelow_skip ["XSS.Raw"]
  def json_ld_script(assigns) do
    ~H"""
    <script type="application/ld+json" nonce={@nonce}>
      <%= Phoenix.HTML.raw(@json_ld) %>
    </script>
    """
  end
end
