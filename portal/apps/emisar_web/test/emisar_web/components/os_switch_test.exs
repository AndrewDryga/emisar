defmodule EmisarWeb.Components.OsSwitchTest do
  @moduledoc """
  The Linux / Windows / macOS switch and the two panels built on it —
  `CoreComponents.os_switch/1` + `os_code_panel/1` (console) and
  `DocsComponents.os_docs_code/1` (docs).

  The load-bearing contract is that the switch is a CONVENIENCE, never a gate:
  every spelling stays in the DOM (the inactive ones only carry `hidden`), so a
  crawler, a reader with no JS, and a reader on another platform all still
  reach the command. The rest pins the markup `assets/js/os_tabs.js` drives.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias EmisarWeb.CoreComponents
  alias EmisarWeb.DocsComponents

  @tabs [
    %{os: :linux, label: "Linux"},
    %{os: :windows, label: "Windows"},
    %{os: :macos, label: "macOS"}
  ]

  describe "os_switch/1" do
    test "renders one named tab per OS" do
      assigns = %{tabs: @tabs}

      html =
        rendered_to_string(~H|<CoreComponents.os_switch detected={:windows} tabs={@tabs} />|)

      assert html =~ ~s(data-os-select="linux")
      assert html =~ ~s(data-os-select="windows")
      assert html =~ ~s(data-os-select="macos")
      assert html =~ "Linux"
      assert html =~ "Windows"
      assert html =~ "macOS"
    end

    test "exactly the detected option reads as pressed" do
      assigns = %{tabs: @tabs}

      html = rendered_to_string(~H|<CoreComponents.os_switch detected={:linux} tabs={@tabs} />|)

      # A labelled button group, not role="tablist": a tab owes a screen reader
      # an aria-controls tabpanel, and the docs variant's pre has no id.
      assert html =~ ~s(role="group")
      assert html =~ ~s(aria-label="Operating system")
      assert length(String.split(html, ~s(aria-pressed="true"))) == 2
      assert length(String.split(html, ~s(aria-pressed="false"))) == 3
    end
  end

  describe "os_code_panel/1" do
    test "every command renders; only the detected one is visible" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.os_code_panel id="install" detected={:macos}>
          <:tab os={:linux} label="Linux" code="curl … | sudo bash" />
          <:tab os={:windows} label="Windows" code="irm … | iex" />
          <:tab os={:macos} label="macOS" code="curl … | sudo bash" />
        </CoreComponents.os_code_panel>
        """)

      assert html =~ "curl … | sudo bash"
      assert html =~ "irm … | iex"
      assert html =~ ~s(id="install-linux")
      assert html =~ ~s(id="install-windows")
      assert html =~ ~s(id="install-macos")
      # The pre carries the OS marker os_tabs.js toggles, and the variants the
      # visitor is not on start hidden.
      assert html =~ ~s(data-os="windows")
      assert html =~ "hidden"
    end

    test "each variant carries its own Copy, targeting its own pre" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.os_code_panel id="install" detected={:windows}>
          <:tab os={:linux} label="Linux" code="curl …" />
          <:tab os={:windows} label="Windows" code="irm …" />
          <:tab os={:macos} label="macOS" code="curl …" />
        </CoreComponents.os_code_panel>
        """)

      assert html =~ ~s(data-copy="#install-linux")
      assert html =~ ~s(data-copy="#install-windows")
      assert html =~ ~s(data-copy="#install-macos")
    end

    test "the code renders escaped" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.os_code_panel id="install" detected={:linux}>
          <:tab os={:linux} label="Linux" code="<script>alert(1)</script>" />
          <:tab os={:windows} label="Windows" code="irm …" />
        </CoreComponents.os_code_panel>
        """)

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "os_docs_code/1" do
    test "every transcript renders, and Copy carries each variant's literal" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <DocsComponents.os_docs_code detected={:linux}>
          <:tab os={:linux} label="Linux" copy_text="curl -fsSL … | sudo bash">$ curl</:tab>
          <:tab os={:windows} label="Windows" copy_text="irm … | iex">PS&gt; irm</:tab>
          <:tab os={:macos} label="macOS" copy_text="curl -fsSL … | sudo bash">$ curl</:tab>
        </DocsComponents.os_docs_code>
        """)

      # The pre carries display chrome ($ / PS>), so Copy takes the paste-ready
      # literal rather than the transcript's textContent.
      assert html =~ ~s(data-copy-text="curl -fsSL … | sudo bash")
      assert html =~ ~s(data-copy-text="irm … | iex")
      assert html =~ ~s(data-os-select="macos")
    end
  end
end
