defmodule EmisarWeb.Components.VersionUpgradeNoticeTest do
  @moduledoc """
  Renders `EmisarWeb.CoreComponents.version_upgrade_notice/1`, the actionable
  runner and MCP stale-version treatment used by list and detail pages.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents

  describe "version_upgrade_notice/1" do
    test "renders one runner command for the most severe stale status" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.version_upgrade_notice
          id="runner-upgrade"
          kind={:runner}
          versions={["0.0.5", "0.0.0"]}
          base_url="https://control.example/"
        />
        """)

      assert html =~ "2 runners need an update"
      assert html =~ "hero-cloud-arrow-down"
      assert html =~ "bg-amber-300/40"
      refute html =~ "bg-amber-500/10"
      refute html =~ "bg-rose-500/10"
      assert html =~ "1 runner is below the supported range"
      assert html =~ "1 runner is behind the recommended release"
      assert html =~ "space-y-4"
      assert html =~ "curl -sSL https://control.example/install.sh | sudo bash"
      assert html =~ ~s(data-copy-text="curl -sSL https://control.example/install.sh | sudo bash")
      assert html =~ "overflow-hidden text-ellipsis whitespace-nowrap"
      assert html =~ "min-h-9"
      refute html =~ "overflow-x-auto"
      refute html =~ "Upgrade command"
    end

    test "renders MCP restart instructions for an outdated bridge" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.version_upgrade_notice
          id="mcp-upgrade"
          kind={:mcp}
          versions={["0.0.5"]}
          base_url="https://control.example"
        />
        """)

      assert html =~ "MCP bridge update available"
      assert html =~ "then restart its LLM client"
      assert html =~ "curl -sSL https://control.example/install-mcp.sh | sudo bash"
    end

    test "renders nothing when versions are current or unknown" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.version_upgrade_notice
          id="no-upgrade"
          kind={:runner}
          versions={["1.0.0", nil, "dev"]}
          base_url="https://control.example"
        />
        """)

      assert String.trim(html) == ""
    end
  end
end
