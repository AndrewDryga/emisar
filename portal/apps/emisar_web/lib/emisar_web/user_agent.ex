defmodule EmisarWeb.UserAgent do
  @moduledoc """
  Minimal User-Agent parser for server-side analytics enrichment — maps the
  request UA to Mixpanel's `$browser` / `$browser_version` / `$os` / `$device`
  special properties (Mixpanel does NOT parse the UA for server-side events;
  the client SDK would).

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
end
