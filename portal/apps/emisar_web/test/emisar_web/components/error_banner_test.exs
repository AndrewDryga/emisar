defmodule EmisarWeb.Components.ErrorBannerTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.error_banner/1` — the card/section-level
  rose error box (icon + message) for a failure with no single form field to
  bind to. Asserts the contract: the message renders, the shared rose box +
  icon are present, extra `class` appends, and the message is HTML-escaped
  (it can carry a changeset/validation string — IL-16).
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EmisarWeb.CoreComponents

  defp render_error_banner(attrs, message) do
    assigns = %{attrs: attrs, message: message}

    rendered_to_string(~H"""
    <CoreComponents.error_banner {@attrs}>{@message}</CoreComponents.error_banner>
    """)
  end

  describe "error_banner/1" do
    test "renders the message inside the shared rose box with an icon" do
      html = render_error_banner(%{}, "Runbook definition is invalid")

      assert html =~ "Runbook definition is invalid"
      assert html =~ "border-rose-500/40"
      assert html =~ "bg-rose-500/10"
      assert html =~ "text-rose-200"
      assert html =~ "hero-exclamation-circle-mini"
    end

    test "appends extra class for positioning" do
      assert render_error_banner(%{class: "mt-4"}, "boom") =~ "mt-4"
    end

    test "the message is HTML-escaped — it can carry a validation string (IL-16)" do
      html = render_error_banner(%{}, "<script>alert(1)</script>")

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
