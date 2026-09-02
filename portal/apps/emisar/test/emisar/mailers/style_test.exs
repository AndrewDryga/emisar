defmodule Emisar.Mailers.StyleTest do
  @moduledoc """
  The two properties that keep an email dark in a client that rewrites colors.

  Grounds are painted with a gradient, which a rewrite skips, so they never move.
  Text is rewritten wherever it sits, so every tone has to be legible on those
  frozen grounds twice: as authored, and after its lightness is flipped.
  """
  use ExUnit.Case, async: true
  alias Emisar.Mailers.MonthlyReport
  alias Emisar.Mailers.Style
  alias Emisar.Mailers.Transactional
  alias Emisar.Users

  # Grounds are painted, never drawn on; a hairline is a separator and is
  # deliberately below text contrast; the button fill is judged with its label.
  @grounds [:ground, :surface]
  @chrome [:hairline, :button_fill]

  describe "the palette" do
    test "every ink clears 4.5:1 on both frozen grounds, before and after a flip" do
      for ink <- ink_tokens(), ground <- @grounds do
        color = apply(Style, ink, [])
        bg = apply(Style, ground, [])

        assert contrast(color, bg) >= 4.5,
               "#{ink} (#{color}) on #{ground} (#{bg}) is #{contrast(color, bg)}:1"

        assert contrast(mirror(color), bg) >= 4.5,
               "#{ink} flips to #{mirror(color)}, which on #{ground} (#{bg}) " <>
                 "is #{contrast(mirror(color), bg)}:1"
      end
    end

    test "the button's label clears 4.5:1 on its frozen fill, before and after a flip" do
      assert contrast(Style.brand(), Style.button_fill()) >= 4.5
      assert contrast(mirror(Style.brand()), Style.button_fill()) >= 4.5
    end
  end

  describe "every rendered body" do
    test "paints its grounds, so a client that rewrites colors cannot turn one light" do
      for {name, html} <- rendered_bodies() do
        refute html =~ "background-color",
               "#{name}: a background-color is rewritten to its opposite, which turns " <>
                 "this email light in Gmail's dark mode. Use Style.fill/1."

        refute html =~ ~r/border(-top|-bottom|-left|-right)?:\s*1px/,
               "#{name}: a border is not a background and cannot be frozen, so it " <>
                 "flips to a bright line. Use Style.rule/1 or a fill inside a fill."
      end
    end

    test "carries the Outlook ground, which renders no gradient" do
      for {name, html} <- rendered_bodies() do
        assert html =~ Style.mso_fallback(:open), "#{name}: no mso ground"
        assert html =~ Style.mso_fallback(:close), "#{name}: unclosed mso ground"
      end
    end
  end

  defp rendered_bodies do
    report = %{
      period_start: ~U[2026-08-01 00:00:00Z],
      period_end: ~U[2026-09-01 00:00:00Z],
      runs: %{
        total: 4,
        success: 3,
        failed: 1,
        denied: 0,
        cancelled: 0,
        dispatched: 4,
        distinct_runners: 1
      },
      approvals: %{
        requested: 2,
        approved: 1,
        denied: 0,
        expired: 0,
        cancelled: 0,
        pending: 1,
        waiting_now: 1
      },
      runners: 1,
      team_size: 2
    }

    monthly =
      MonthlyReport.render(
        %Users.User{full_name: "Olivia Owner", email: "olivia@example.com"},
        %{name: "Fleet Ops", slug: "fleet-ops"},
        report,
        "https://emisar.dev/u"
      )

    transactional =
      Transactional.render(%{
        recipient: "Olivia Owner",
        title: "Approval",
        preview: "Needs approval.",
        blocks: [
          {:status, "This action ", "needs your approval", ".", :warning},
          {:facts, [{"Action", "linux.uptime"}, {"Runner", "web-01"}]},
          {:section, "Redacted arguments"},
          {:pre, "host  web-01"},
          {:code, "834 512"},
          {:list, ["One", "Two"]}
        ],
        action: {"Review approval", "https://emisar.dev/a"},
        secondary_action: {"Open runner", "https://emisar.dev/r"},
        footer: "You're receiving this because you can approve actions."
      })

    [{"monthly report", monthly.html}, {"transactional", transactional.html}]
  end

  defp ink_tokens do
    tokens =
      for {name, 0} <- Style.__info__(:functions),
          name not in @grounds and name not in @chrome,
          match?("#" <> <<_::binary-size(6)>>, apply(Style, name, [])),
          do: name

    # A new color token falls under the test above the moment it is added; an
    # empty list would mean the reflection stopped finding any of them.
    assert tokens != []
    tokens
  end

  # A rewriting client keeps hue and saturation and flips HSL lightness.
  defp mirror(hex) do
    {h, l, s} = to_hsl(hex)
    to_hex(h, 1.0 - l, s)
  end

  defp contrast(a, b) do
    [high, low] = Enum.sort([luminance(a), luminance(b)], :desc)
    Float.round((high + 0.05) / (low + 0.05), 2)
  end

  defp luminance(hex) do
    [r, g, b] = channels(hex)
    0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
  end

  defp linear(channel) when channel <= 0.03928, do: channel / 12.92
  defp linear(channel), do: :math.pow((channel + 0.055) / 1.055, 2.4)

  defp channels("#" <> hex) do
    hex
    |> String.to_charlist()
    |> Enum.chunk_every(2)
    |> Enum.map(&(List.to_integer(&1, 16) / 255))
  end

  defp to_hsl(hex) do
    [r, g, b] = channels(hex)
    high = Enum.max([r, g, b])
    low = Enum.min([r, g, b])
    chroma = high - low
    l = (high + low) / 2
    {hue(r, g, b, high, chroma), l, saturation(chroma, l)}
  end

  defp saturation(chroma, _l) when chroma == 0, do: 0.0
  defp saturation(chroma, l), do: chroma / (1 - abs(2 * l - 1))

  defp hue(_r, _g, _b, _high, chroma) when chroma == 0, do: 0.0
  defp hue(r, g, b, high, chroma) when high == r, do: wrap((g - b) / chroma) / 6
  defp hue(r, g, b, high, chroma) when high == g, do: ((b - r) / chroma + 2) / 6
  defp hue(r, g, _b, _high, chroma), do: ((r - g) / chroma + 4) / 6

  defp wrap(sector) when sector < 0, do: sector + 6
  defp wrap(sector), do: sector

  defp to_hex(h, l, s) do
    chroma = (1 - abs(2 * l - 1)) * s
    sector = h * 6
    x = chroma * (1 - abs(:math.fmod(sector, 2) - 1))
    m = l - chroma / 2

    parts = rgb(sector, chroma, x)
    "#" <> Enum.map_join(parts, &byte(round((&1 + m) * 255)))
  end

  defp byte(value) do
    value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
  end

  defp rgb(sector, chroma, x) when sector < 1, do: [chroma, x, 0]
  defp rgb(sector, chroma, x) when sector < 2, do: [x, chroma, 0]
  defp rgb(sector, chroma, x) when sector < 3, do: [0, chroma, x]
  defp rgb(sector, chroma, x) when sector < 4, do: [0, x, chroma]
  defp rgb(sector, chroma, x) when sector < 5, do: [x, 0, chroma]
  defp rgb(_sector, chroma, x), do: [chroma, 0, x]
end
