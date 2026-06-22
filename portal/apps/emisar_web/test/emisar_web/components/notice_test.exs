defmodule EmisarWeb.Components.NoticeTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.notice/1` — the informational banner sibling
  of `<.error_banner>`. Asserts each severity's tone + icon and that the message
  is escaped (IL-16: notices carry interpolated, attacker-influenceable text).
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias EmisarWeb.CoreComponents

  describe "notice/1" do
    test "warning is amber with a triangle" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H"<CoreComponents.notice variant={:warning}>Copy it now.</CoreComponents.notice>"
        )

      assert html =~ "Copy it now."
      assert html =~ "bg-amber-500/10"
      assert html =~ "hero-exclamation-triangle-mini"
    end

    test "success is emerald with a check" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H"<CoreComponents.notice variant={:success}>Published.</CoreComponents.notice>"
        )

      assert html =~ "bg-brand-500/10"
      assert html =~ "hero-check-circle-mini"
    end

    test "info is the indigo default" do
      assigns = %{}

      html = rendered_to_string(~H"<CoreComponents.notice>Heads up.</CoreComponents.notice>")

      assert html =~ "bg-brand-500/10"
      assert html =~ "hero-information-circle-mini"
    end

    test "escapes interpolated message text" do
      assigns = %{evil: "<script>alert(1)</script>"}

      html = rendered_to_string(~H"<CoreComponents.notice>{@evil}</CoreComponents.notice>")

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
