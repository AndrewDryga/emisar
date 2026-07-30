defmodule EmisarWeb.RunbookMarkdownTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias EmisarWeb.RunbookMarkdown

  test "renders the operator-oriented Markdown subset as semantic structure" do
    html =
      render_component(&RunbookMarkdown.render/1,
        markdown: """
        ## Before you run

        Confirm the incident scope.

        - Check the dashboard
        - Notify the incident lead

        1. Inspect
        2. Remediate

        ```sh
        emisar status
        ```
        """
      )

    assert html =~ "<h3"
    assert html =~ "Before you run"
    assert html =~ "<ul"
    assert html =~ "<ol"
    assert html =~ "<pre"
    assert html =~ "emisar status"
  end

  test "never interprets authored HTML, links, images, or scripts" do
    html =
      render_component(&RunbookMarkdown.render/1,
        markdown: "<script>alert(1)</script>\n\n![remote](https://tracker.invalid/pixel)"
      )

    refute html =~ "<script>"
    refute html =~ "<img"
    refute html =~ ~s(href="https://tracker.invalid)
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert html =~ "![remote]"
  end

  test "an unfinished fence remains a safe code block" do
    html = render_component(&RunbookMarkdown.render/1, markdown: "```json\n{\"ok\": true}")

    assert html =~ "<pre"
    assert html =~ "&quot;ok&quot;"
  end
end
