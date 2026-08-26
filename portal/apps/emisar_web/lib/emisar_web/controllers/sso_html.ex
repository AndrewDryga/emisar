defmodule EmisarWeb.SSOHTML do
  @moduledoc "The same-origin handoff page that opens an external OIDC authorization request."
  use EmisarWeb, :html

  embed_templates "sso_html/*"
end
