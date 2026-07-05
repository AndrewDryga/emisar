defmodule EmisarWeb.Components.DetailHeaderTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.detail_header/1` — the breadcrumb + heading
  block for a title-less detail page. Asserts the `<.back_link>` carries the
  parent target + label, the heading slot renders after it, and interpolated
  heading text is escaped (IL-16: detail headings carry no `raw/1`).
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "detail_header/1" do
    test "renders the back-link to the parent list, then the heading" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.detail_header back="Runners" navigate="/app/runners">
          acme-db-01
        </CoreComponents.detail_header>
        """)

      assert html =~ ~s(href="/app/runners")
      assert html =~ "Runners"
      assert html =~ "acme-db-01"
      # The breadcrumb separator the back_link owns is present.
      assert html =~ "/"
    end

    test "the heading slot keeps its own markup (mono id, version suffix, …)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.detail_header back="Runbooks" navigate="/app/runbooks">
          Edit runbook <span class="font-mono">my-slug</span>
        </CoreComponents.detail_header>
        """)

      assert html =~ "Edit runbook"
      assert html =~ ~s(<span class="font-mono">my-slug</span>)
    end

    test "title + mono render the machine-id heading face" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.detail_header back="Runners" navigate="/app/runners" title="api-iad-3" mono />
        """)

      assert html =~ "api-iad-3"
      assert html =~ "font-mono text-lg tracking-tight sm:text-xl"
    end

    test "a plain title renders without the mono face" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.detail_header back="Single sign-on" navigate="/app/sso" title="Acme Okta" />
        """)

      assert html =~ "Acme Okta"
      refute html =~ "font-mono"
    end

    test "a mono title's meta speaks the title's face, dimmed to the breadcrumb gray" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.detail_header back="Runs" navigate="/app/runs" title="nginx_reload" mono>
          <:meta>on api-iad-3</:meta>
        </CoreComponents.detail_header>
        """)

      assert html =~ "on api-iad-3"
      # Same mono size as the title, zinc-400 like the back link — one heading
      # line, not a heading plus a footnote.
      assert html =~ "font-mono text-lg tracking-tight text-zinc-400 sm:text-xl"
    end

    test "escapes interpolated heading text (no raw HTML injection)" do
      assigns = %{evil: "<script>alert(1)</script>"}

      html =
        rendered_to_string(~H"""
        <CoreComponents.detail_header back="Audit log" navigate="/app/audit">
          {@evil}
        </CoreComponents.detail_header>
        """)

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
