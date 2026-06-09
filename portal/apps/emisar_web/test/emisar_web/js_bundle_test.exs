defmodule EmisarWeb.JsBundleTest do
  @moduledoc """
  The static marketing site is server-rendered and has no LiveView socket,
  so it must load only the lean `marketing.js` — never the full `app.js`
  (LiveSocket + hooks + topbar, ~50 KiB it would never use). LiveView
  pages load `app.js`. The split is driven by the `@app_js?` assign that
  the global LiveView `on_mount` hook sets on every live render, read in
  `root.html.heex`.
  """
  use EmisarWeb.ConnCase, async: true

  describe "JS bundle split (marketing vs app)" do
    test "marketing (controller-rendered) pages load only the lean marketing.js", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ "/assets/marketing.js"
      refute html =~ "/assets/app.js"
    end

    test "LiveView pages load the full app.js bundle", %{conn: conn} do
      # /sign_in is a public LiveView, so its disconnected (dead) render
      # exercises the on_mount hook → @app_js? → app.js.
      html = conn |> get(~p"/sign_in") |> html_response(200)
      assert html =~ "/assets/app.js"
      refute html =~ "/assets/marketing.js"
    end
  end
end
