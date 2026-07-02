defmodule EmisarWeb.UserAgent do
  @moduledoc """
  Minimal User-Agent parser — ONE parsing brain for every surface that
  reads a UA: `parse/1` feeds server-side analytics enrichment (Mixpanel's
  `$browser` / `$browser_version` / `$os` / `$device` special properties —
  Mixpanel does NOT parse the UA for server-side events), and `label/1` /
  `icon/1` render the compact device line on the audit detail's actor card
  and the profile page's session list.

  Deliberately small and dependency-free: it covers the browsers/OSes that
  make up the overwhelming majority of real traffic and returns `nil` for
  anything it doesn't recognize (the caller omits a `nil` property). Order
  matters — Edge / Opera / Samsung all carry "Chrome" in their UA, so the
  specific tokens are checked first.
  """

  @type t :: %{
          browser: String.t() | nil,
          browser_version: String.t() | nil,
          os: String.t() | nil,
          device: String.t() | nil
        }

  @spec parse(String.t() | nil) :: t()
  def parse(user_agent) when is_binary(user_agent) do
    name = browser(user_agent)

    %{
      browser: name,
      browser_version: browser_version(user_agent, name),
      os: os(user_agent),
      device: device(user_agent)
    }
  end

  def parse(_), do: %{browser: nil, browser_version: nil, os: nil, device: nil}

  defp browser(ua) do
    cond do
      String.contains?(ua, "Edg/") -> "Microsoft Edge"
      String.contains?(ua, "OPR/") or String.contains?(ua, "Opera") -> "Opera"
      String.contains?(ua, "SamsungBrowser/") -> "Samsung Internet"
      String.contains?(ua, "Firefox/") -> "Firefox"
      String.contains?(ua, "Chrome/") -> "Chrome"
      String.contains?(ua, "Mobile") and String.contains?(ua, "Safari") -> "Mobile Safari"
      String.contains?(ua, "Safari") -> "Safari"
      true -> nil
    end
  end

  # The version sits after a browser-specific token; Safari keeps its real
  # version in `Version/x`, not the `Safari/x` build number.
  defp browser_version(_ua, nil), do: nil
  defp browser_version(ua, "Microsoft Edge"), do: version_after(ua, "Edg/")

  defp browser_version(ua, "Opera"),
    do: version_after(ua, "OPR/") || version_after(ua, "Version/")

  defp browser_version(ua, "Samsung Internet"), do: version_after(ua, "SamsungBrowser/")
  defp browser_version(ua, "Firefox"), do: version_after(ua, "Firefox/")
  defp browser_version(ua, "Chrome"), do: version_after(ua, "Chrome/")
  defp browser_version(ua, "Mobile Safari"), do: version_after(ua, "Version/")
  defp browser_version(ua, "Safari"), do: version_after(ua, "Version/")

  defp version_after(ua, token) do
    case Regex.run(~r/#{Regex.escape(token)}(\d+(?:\.\d+)?)/, ua) do
      [_, version] -> version
      _ -> nil
    end
  end

  defp os(ua) do
    cond do
      String.contains?(ua, "Windows NT") -> "Windows"
      String.contains?(ua, "iPhone") or String.contains?(ua, "iPad") -> "iOS"
      String.contains?(ua, "Mac OS X") -> "Mac OS X"
      String.contains?(ua, "Android") -> "Android"
      String.contains?(ua, "CrOS") -> "Chrome OS"
      String.contains?(ua, "Linux") -> "Linux"
      true -> nil
    end
  end

  defp device(ua) do
    cond do
      String.contains?(ua, "iPhone") -> "iPhone"
      String.contains?(ua, "iPad") -> "iPad"
      String.contains?(ua, "Android") -> "Android"
      true -> nil
    end
  end

  @doc """
  Compact display label built on `parse/1` — "Chrome on Mac", one side
  when only one parses, the first UA token as a last resort, and
  "Unknown device" for a missing UA.
  """
  def label(user_agent) when is_binary(user_agent) do
    case parse(user_agent) do
      %{browser: nil, os: nil} -> short_ua(user_agent)
      %{browser: browser, os: nil} -> display_browser(browser)
      %{browser: nil, os: os} -> display_os(os)
      %{browser: browser, os: os} -> "#{display_browser(browser)} on #{display_os(os)}"
    end
  end

  def label(_), do: "Unknown device"

  @doc """
  Hero icon name hinting at the device class — phone / desktop browser /
  bare Go client (the runner's signature) / globe fallback.
  """
  def icon(user_agent) when is_binary(user_agent) do
    cond do
      user_agent =~ ~r/iPhone|iPad|Android/i -> "hero-device-phone-mobile"
      user_agent =~ ~r/Mozilla|WebKit/i -> "hero-computer-desktop"
      user_agent =~ ~r/^Go-http-client/i -> "hero-server"
      true -> "hero-globe-alt"
    end
  end

  def icon(_), do: "hero-globe-alt"

  @doc """
  A bare Go HTTP client that didn't set a custom UA — the runner's
  signature. Callers hide the device line for it: a machine client isn't
  a "device" worth showing.
  """
  def go_http_client?(user_agent) when is_binary(user_agent),
    do: user_agent =~ ~r/^Go-http-client/i

  def go_http_client?(_), do: false

  # `parse/1` names are Mixpanel-canonical ("Microsoft Edge", "Mac OS X");
  # the device line wants the short everyday forms.
  defp display_browser("Microsoft Edge"), do: "Edge"
  defp display_browser("Mobile Safari"), do: "Safari"
  defp display_browser(browser), do: browser

  defp display_os("Mac OS X"), do: "Mac"
  defp display_os(os), do: os

  # Last-resort: the first whitespace-delimited token, so a missing UA
  # parser doesn't print a 200-char Mozilla string into the card.
  defp short_ua(user_agent) do
    case Regex.run(~r{^([^\s]+)}, user_agent) do
      [_, token] -> token
      _ -> "Unknown device"
    end
  end
end
