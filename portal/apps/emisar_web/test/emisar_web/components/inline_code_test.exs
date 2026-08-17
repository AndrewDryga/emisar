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
    assert html =~ ~r/<code[^>]*>\s*linux\.uptime\s*<\/code>/
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
    assert html =~ ~r/>\s*deny\s*</
  end
end
