defmodule Emisar.Mailers.StyleTest do
  @moduledoc """
  The properties that keep the design intact in a client that rewrites colors.

  Surfaces are painted so a rewrite skips them, neutral text is carried through
  by `Style.blend/1`, and accents — which no blend can carry, being RGB math
  against an HSL flip — sit at the one lightness a flip leaves alone.
  """
  use ExUnit.Case, async: true
  alias Emisar.Mailers.MonthlyReport
  alias Emisar.Mailers.Style
  alias Emisar.Mailers.Transactional
  alias Emisar.Users

  @grounds [:ground, :surface]
  # Painted, never drawn on: a hairline separates and the fill carries a label.
  @chrome [:hairline, :button_fill]
  # Carried through a rewrite by blend/1, so their lightness is unconstrained.
  @neutrals [:ink, :ink_soft]

  describe "the palette" do
    test "every tone clears 4.5:1 on both grounds" do
      for token <- text_tokens(), ground <- @grounds do
        color = apply(Style, token, [])
        bg = apply(Style, ground, [])

        assert contrast(color, bg) >= 4.5,
               "#{token} (#{color}) on #{ground} (#{bg}) is #{contrast(color, bg)}:1"
      end
    end

    test "every accent sits at the one lightness a rewrite leaves alone" do
      for accent <- text_tokens() -- @neutrals do
        color = apply(Style, accent, [])
        {_h, lightness, _s} = to_hsl(color)

        assert_in_delta lightness,
                        0.5,
                        0.005,
                        "#{accent} (#{color}) is at #{round(lightness * 100)}% lightness, so a " <>
                          "rewrite moves it. No blend can carry a hue — put it at 50%."
      end
    end

    test "the button's label clears 4.5:1 on its fill" do
      assert contrast(Style.ink(), Style.button_fill()) >= 4.5
    end
  end

  describe "every rendered body" do
    test "carries the Gmail stylesheet and the class it keys off" do
      for {name, html} <- rendered_bodies() do
        assert html =~ "u + .body", "#{name}: no Gmail-only block"
        assert html =~ ~s(<body class="body ), "#{name}: nothing for `u + .body` to match"
      end
    end

    test "paints every surface, so a rewrite cannot turn one light" do
      for {name, html} <- rendered_bodies(), background <- backgrounds(html) do
        assert background =~ ~r/class="[^"]*gm-(ground|surface|hairline|fill)/,
               "#{name}: a background-color with no gm- class is rewritten to its " <>
                 "opposite. Pair Style.fill/1 with the class Gmail repaints it by."
      end
    end

    test "draws its edges as backgrounds, because a border cannot be painted" do
      for {name, html} <- rendered_bodies() do
        refute html =~ ~r/border(-top|-bottom|-left|-right)?:\s*1px/,
               "#{name}: a border is not a background, so it flips to a bright line. " <>
                 "Use Style.rule/1, or a fill inside a fill."
      end
    end
  end

  defp backgrounds(html) do
    ~r/<[a-z]+[^>]*background-color:[^>]*>/
    |> Regex.scan(html)
    |> Enum.map(&hd/1)
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
          {:code, "834 512"}
        ],
        action: {"Review approval", "https://emisar.dev/a"},
        secondary_action: {"Open runner", "https://emisar.dev/r"},
        footer: "You're receiving this because you can approve actions."
      })

    [{"monthly report", monthly.html}, {"transactional", transactional.html}]
  end

  defp text_tokens do
    tokens =
      for {name, 0} <- Style.__info__(:functions),
          name not in @grounds and name not in @chrome,
          match?("#" <> <<_::binary-size(6)>>, apply(Style, name, [])),
          do: name

    # A new color token falls under both tests the moment it is added; an empty
    # list would mean the reflection stopped finding any of them.
    assert tokens != []
    tokens
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
    lightness = (high + low) / 2
    {hue(r, g, b, high, chroma), lightness, saturation(chroma, lightness)}
  end

  defp saturation(chroma, _lightness) when chroma == 0, do: 0.0
  defp saturation(chroma, lightness), do: chroma / (1 - abs(2 * lightness - 1))

  defp hue(_r, _g, _b, _high, chroma) when chroma == 0, do: 0.0
  defp hue(r, g, b, high, chroma) when high == r, do: wrap((g - b) / chroma) / 6
  defp hue(r, g, b, high, chroma) when high == g, do: ((b - r) / chroma + 2) / 6
  defp hue(r, g, _b, _high, chroma), do: ((r - g) / chroma + 4) / 6

  defp wrap(sector) when sector < 0, do: sector + 6
  defp wrap(sector), do: sector
end
