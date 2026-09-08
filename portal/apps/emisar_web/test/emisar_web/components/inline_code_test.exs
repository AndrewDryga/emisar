defmodule EmisarWeb.Components.InlineCodeTest do
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  test "renders backtick spans inside plain text" do
    assigns = %{}

    html =
      rendered_to_string(~H|<CoreComponents.inline_code text="Run `linux.uptime` now." />|)

    assert html =~ "Run "

    assert html |> LazyHTML.from_fragment() |> LazyHTML.query("code") |> LazyHTML.text() ==
             "linux.uptime"

    assert html =~ " now."
  end

  test "renders a direct console code value through the shared variants" do
    assigns = %{}

    html =
      rendered_to_string(
        ~H|<CoreComponents.inline_code surface={:diff} size={:compact}>deny</CoreComponents.inline_code>|
      )

    assert html =~ "bg-zinc-800/60"
    assert html =~ "text-[11px]"
    assert html |> LazyHTML.from_fragment() |> LazyHTML.query("code") |> LazyHTML.text() == "deny"
  end

  test "preserves intentional spaces without adding template whitespace" do
    assigns = %{}

    html =
      rendered_to_string(
        ~H|<CoreComponents.inline_code>{" coop codex "}</CoreComponents.inline_code>|
      )

    assert html |> LazyHTML.from_fragment() |> LazyHTML.query("code") |> LazyHTML.text() ==
             " coop codex "
  end

  test "escapes literal code content" do
    assigns = %{value: "<script>alert(1)</script>"}

    html =
      rendered_to_string(~H|<CoreComponents.inline_code>{@value}</CoreComponents.inline_code>|)

    refute html =~ "<script>"

    assert html |> LazyHTML.from_fragment() |> LazyHTML.query("code") |> LazyHTML.text() ==
             assigns.value
  end
end
