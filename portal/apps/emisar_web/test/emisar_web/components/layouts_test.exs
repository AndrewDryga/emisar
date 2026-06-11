defmodule EmisarWeb.LayoutsTest do
  @moduledoc """
  Direct renders of the two embedded layouts — LiveViewTest mounts skip
  them, so without this nothing executes the templates at all.
  """
  use EmisarWeb.ConnCase, async: true

  test "app layout wraps the inner content with the flash group" do
    html =
      Phoenix.Template.render_to_string(EmisarWeb.Layouts, "app", "html",
        flash: %{},
        inner_content: "INNER-MARKER"
      )

    assert html =~ "INNER-MARKER"
  end

  test "root layout renders the document shell" do
    html =
      Phoenix.Template.render_to_string(EmisarWeb.Layouts, "root", "html",
        flash: %{},
        inner_content: "BODY-MARKER",
        app_js: "",
        canonical_url: nil,
        json_ld: nil,
        page_title: nil
      )

    assert html =~ "<!DOCTYPE html>"
    assert html =~ "BODY-MARKER"
  end
end
