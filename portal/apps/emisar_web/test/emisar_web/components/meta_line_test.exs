defmodule EmisarWeb.Components.MetaLineTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.meta_line/1` (the ONE `a · b · c` meta
  row) and `code_line/1` (the one-line code value + copy button). Asserts
  separators render only between VISIBLE segments — a hidden segment can't
  leave a dangling or doubled middot.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  defp render_line(assigns) do
    rendered_to_string(~H"""
    <CoreComponents.meta_line class="text-[11px]">
      <:seg mono>emk_abc…</:seg>
      <:seg :if={@show_uses}>3 uses</:seg>
      <:seg>last used never</:seg>
    </CoreComponents.meta_line>
    """)
  end

  defp visible_text(html) do
    html
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  describe "meta_line/1" do
    test "joins visible segments with middots; mono is per-segment" do
      html = render_line(%{show_uses: true})

      assert visible_text(html) == "emk_abc… · 3 uses · last used never"
      # The id segment carries mono; the LINE wrapper never does — a timestamp
      # or email segment must render in the reading face, not mono.
      assert html =~ ~r{class="font-mono">\s*emk_abc…}
      refute html =~ "sm:truncate font-mono"
      assert html =~ "text-[11px]"
    end

    test "a hidden segment leaves no dangling or doubled middot" do
      html = render_line(%{show_uses: false})

      assert visible_text(html) == "emk_abc… · last used never"
    end
  end

  describe "code_line/1" do
    test "renders the value in a copyable framed row" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.code_line id="sign-in-link" value="https://emisar.dev/a/acme" class="mt-3" />
        """)

      assert html =~ ~s(id="sign-in-link")
      assert html =~ ~s(data-copy-text="https://emisar.dev/a/acme")
      assert html =~ "https://emisar.dev/a/acme"
      assert html =~ "bg-zinc-950/80"
      # A URL is one line that scrolls, not a break-all block that wraps.
      assert html =~ "whitespace-nowrap"
      refute html =~ "break-all"
    end

    test "wraps a short command and names its copy action when requested" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.code_line
          id="upgrade-command"
          label="Remote MCP server URL"
          value="curl https://emisar.dev/install.sh | sudo bash"
        />
        """)

      assert html =~ "Remote MCP server URL"
      assert html =~ "min-h-9"
      assert html =~ "overflow-hidden text-ellipsis whitespace-nowrap"
      refute html =~ "overflow-x-auto"
      refute html =~ "min-h-10"
      assert html =~ ~r/>
\s*Copy\s*
<\/button>/
      assert html =~ ">curl https://emisar.dev/install.sh | sudo bash</code>"
      assert html =~ ~s(data-copy-text="curl https://emisar.dev/install.sh | sudo bash")
    end
  end
end
