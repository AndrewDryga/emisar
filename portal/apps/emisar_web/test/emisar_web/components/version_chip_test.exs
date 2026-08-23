defmodule EmisarWeb.Components.VersionChipTest do
  @moduledoc """
  Renders `EmisarWeb.DomainComponents.version_chip/1` — the quiet marker beside a
  runner or bridge version on a list row and a detail page. Its tooltip is where
  an operator standing on that row learns what to run, so the command rides the
  bubble's copyable row instead of being spelled into the sentence.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.DomainComponents

  describe "version_chip/1" do
    test "an outdated runner names the release and hands over the command" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DomainComponents.version_chip kind={:runner} version="0.0.5" id="runner-version-7" />
        """)

      assert html =~ "Runner v0.1.0 is available"
      assert html =~ "this one is on v0.0.5"
      assert html =~ "Run the command on this host"
      # The founder's report: the command read as prose mid-sentence. It is now
      # the copyable mono row the page-level notice uses for the same command.
      refute html =~ "Run sudo emisar update on this host"
      assert html =~ ~s(id="runner-version-7-command")
      assert html =~ ~s(data-copy-text="sudo emisar update")
      assert html =~ "state.update_available"
    end

    test "an unsupported runner gets the same command as the merely stale one" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DomainComponents.version_chip kind={:runner} version="0.0.0" id="runner-version-9" />
        """)

      assert html =~ "Below the minimum runner version"
      assert html =~ "run the command on this host"
      assert html =~ ~s(id="runner-version-9-command")
      assert html =~ ~s(data-copy-text="sudo emisar update")
      assert html =~ "unsupported"
    end

    test "a stale bridge leaves its installer one-liner to the agents notice" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DomainComponents.version_chip kind={:mcp} version="0.0.5" id="mcp-version-3" />
        """)

      assert html =~ "emisar-mcp v0.1.0 is available"
      assert html =~ "then restart its LLM client"
      # The bridge command carries the account's own portal URL — too long to
      # read clipped in a bubble, so no command row here.
      refute html =~ "data-copy-text"
    end

    test "a current version renders nothing" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DomainComponents.version_chip kind={:runner} version="0.1.0" id="runner-version-1" />
        """)

      assert String.trim(html) == ""
    end
  end
end
