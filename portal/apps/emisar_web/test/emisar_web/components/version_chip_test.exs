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
      refute html =~ "text-rose-400"
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
      assert html =~ ~s(aria-label="Update required")
      assert html =~ "text-rose-400"
      assert html =~ "emisar-icon-mono"
      assert html =~ "state.update_available"
    end

    test "a stale bridge offers each OS installer for this deployment" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DomainComponents.version_chip
          kind={:mcp}
          version="0.0.5"
          id="mcp-version-3"
          base_url="https://control.example"
          detected_os={:windows}
        />
        """)

      assert html =~ "emisar-mcp v0.1.0 is available"
      assert html =~ "then restart its LLM client"
      document = LazyHTML.from_document(html)

      assert LazyHTML.query(document, "[data-os-select]") |> LazyHTML.attribute("data-os-select") ==
               ["linux", "windows", "macos"]

      assert LazyHTML.query(document, "[data-os]:not(.hidden)") |> LazyHTML.attribute("data-os") ==
               ["windows"]

      assert LazyHTML.query(document, "[data-os='linux'] [data-copy-text]")
             |> LazyHTML.attribute("data-copy-text") ==
               [
                 "curl -fsSL https://control.example/install-mcp.sh | sudo EMISAR_URL=https://control.example bash"
               ]

      assert LazyHTML.query(document, "[data-os='windows'] [data-copy-text]")
             |> LazyHTML.attribute("data-copy-text") ==
               [
                 "& ([scriptblock]::Create((irm 'https://control.example/install-mcp.ps1'))) -PortalOrigin 'https://control.example'"
               ]
    end

    test "an unsupported bridge has a fully red icon and hosted install commands" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DomainComponents.version_chip
          kind={:mcp}
          version="0.0.0"
          id="mcp-old"
          base_url="https://emisar.dev"
        />
        """)

      assert html =~ "Below the minimum emisar-mcp version"
      assert html =~ "emisar-icon-mono"
      assert html =~ "text-rose-400"
      assert html =~ ~s(data-copy-text="curl -fsSL https://emisar.dev/install-mcp.sh | sudo bash")
      assert html =~ ~s(data-copy-text="irm https://emisar.dev/install-mcp.ps1 | iex")
    end

    test "an insecure remote origin never offers a privileged installer" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DomainComponents.version_chip
          kind={:mcp}
          version="0.0.5"
          id="mcp-insecure"
          base_url="http://control.example"
        />
        """)

      assert html =~ "Open emisar over HTTPS"
      refute html =~ "data-copy-text"
    end

    test "missing and unparseable versions render nothing" do
      for version <- [nil, "", "unknown"] do
        assigns = %{version: version}

        html =
          rendered_to_string(~H"""
          <DomainComponents.version_chip
            kind={:mcp}
            version={@version}
            id="mcp-unknown"
            base_url="https://emisar.dev"
          />
          """)

        assert String.trim(html) == ""
      end
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
