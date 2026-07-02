defmodule EmisarWeb.UserAgentTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.UserAgent

  test "desktop Chrome on Windows" do
    ua =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    assert %{browser: "Chrome", browser_version: "120.0", os: "Windows", device: nil} =
             UserAgent.parse(ua)
  end

  test "Mobile Safari on iPhone (iOS detected before the 'like Mac OS X' decoy)" do
    ua =
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 " <>
        "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    assert %{browser: "Mobile Safari", browser_version: "17.5", os: "iOS", device: "iPhone"} =
             UserAgent.parse(ua)
  end

  test "Firefox on macOS" do
    ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:121.0) Gecko/20100101 Firefox/121.0"
    assert %{browser: "Firefox", browser_version: "121.0", os: "Mac OS X"} = UserAgent.parse(ua)
  end

  test "Edge is not mis-detected as Chrome" do
    ua =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"

    assert %{browser: "Microsoft Edge", browser_version: "120.0"} = UserAgent.parse(ua)
  end

  test "Chrome on Android (Chrome wins over the Mobile-Safari token; Android over Linux)" do
    ua =
      "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 " <>
        "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

    assert %{browser: "Chrome", os: "Android", device: "Android"} = UserAgent.parse(ua)
  end

  test "nil and unrecognized agents return all-nil (caller omits the props)" do
    assert %{browser: nil, browser_version: nil, os: nil, device: nil} = UserAgent.parse(nil)
    assert %{browser: nil, os: nil} = UserAgent.parse("curl/8.5.0")
  end

  describe "label/1" do
    test "browser + OS combine with the short everyday names" do
      chrome_mac =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
          "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

      edge_windows =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
          "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"

      safari_iphone =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 " <>
          "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

      assert UserAgent.label(chrome_mac) == "Chrome on Mac"
      assert UserAgent.label(edge_windows) == "Edge on Windows"
      assert UserAgent.label(safari_iphone) == "Safari on iOS"
    end

    test "one recognized side renders alone" do
      assert UserAgent.label("Mozilla/5.0 (Windows NT 10.0)") == "Windows"
      assert UserAgent.label("Chrome/120.0.0.0") == "Chrome"
    end

    test "unrecognized UAs fall back to the first token, nil to Unknown device" do
      assert UserAgent.label("curl/8.5.0") == "curl/8.5.0"
      assert UserAgent.label("emisar-mcp/1.2 (os=darwin)") == "emisar-mcp/1.2"
      assert UserAgent.label(nil) == "Unknown device"
      assert UserAgent.label("") == "Unknown device"
    end
  end

  describe "icon/1" do
    test "phone beats desktop for mobile UAs; Go clients read as servers" do
      assert UserAgent.icon("Mozilla/5.0 (iPhone; ...) AppleWebKit/605.1.15") ==
               "hero-device-phone-mobile"

      assert UserAgent.icon("Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36") ==
               "hero-computer-desktop"

      assert UserAgent.icon("Go-http-client/1.1") == "hero-server"
      assert UserAgent.icon("curl/8.5.0") == "hero-globe-alt"
      assert UserAgent.icon(nil) == "hero-globe-alt"
    end
  end

  describe "go_http_client?/1" do
    test "matches only the bare Go client prefix" do
      assert UserAgent.go_http_client?("Go-http-client/2.0")
      refute UserAgent.go_http_client?("Mozilla/5.0 (Windows NT 10.0)")
      refute UserAgent.go_http_client?(nil)
    end
  end
end
