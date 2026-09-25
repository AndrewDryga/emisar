defmodule Emisar.Mailers.StyleTest do
  @moduledoc """
  The properties that keep the emails dark in the Gmail apps, which ignore
  `color-scheme` and flip the HSL lightness of every authored color.

  Surfaces are painted so the flip skips them, neutral text is carried through
  it by `Style.blend/1`, and accents — which no blend can carry, being RGB math
  against an HSL flip — sit at the one lightness a flip leaves alone. Where a
  Gmail app drops the embedded block, the whole body flips; the neutrals still
  read there.
  """
  use ExUnit.Case, async: true
  alias Emisar.Accounts
  alias Emisar.Mailers.MonthlyReport
  alias Emisar.Mailers.Style
  alias Emisar.Mailers.Transactional

  @grounds [:ground, :surface]
  @neutrals [:ink, :ink_soft]
  @accents [:brand, :rose, :amber]
  # The gm- class `Style.gmail_css/0` repaints each fill by.
  @fills %{
    "gm-ground" => :ground,
    "gm-surface" => :surface,
    "gm-hairline" => :hairline,
    "gm-edge" => :edge,
    "gm-fill" => :button_fill
  }

  describe "the palette" do
    test "every ink clears 4.5:1 on both grounds" do
      for ink <- @neutrals ++ @accents, ground <- @grounds do
        fg = apply(Style, ink, [])
        bg = apply(Style, ground, [])

        assert contrast(fg, bg) >= 4.5, "#{ink} on #{ground}: #{contrast(fg, bg)}"
      end
    end

    test "every accent sits at the one lightness a flip leaves alone" do
      for accent <- @accents do
        color = apply(Style, accent, [])
        {_h, lightness, _s} = to_hls(rgb(color))

        assert_in_delta lightness,
                        0.5,
                        0.005,
                        "#{accent} (#{color}) is at #{round(lightness * 100)}% lightness, so " <>
                          "the flip moves it. No blend can carry a hue — put it at 50%."
      end
    end

    test "the neutrals still clear 4.5:1 where a Gmail app drops the block and flips the body" do
      for ink <- @neutrals, ground <- @grounds do
        fg = flip(apply(Style, ink, []))
        bg = flip(apply(Style, ground, []))

        assert contrast(fg, bg) >= 4.5, "#{ink} on #{ground} flipped: #{contrast(fg, bg)}"
      end
    end

    test "the button's label clears 4.5:1 on its fill" do
      assert contrast(Style.ink(), Style.button_fill()) >= 4.5
    end
  end

  describe "every rendered body" do
    test "declares the dark scheme and puts the masthead on a raster" do
      for {name, html} <- rendered_bodies() do
        assert html =~ ~s(<meta name="color-scheme" content="dark" />), name
        assert html =~ ~s(<meta name="supported-color-schemes" content="dark" />), name
        assert html =~ "color-scheme: dark; supported-color-schemes: dark;", name
        assert html =~ ~s(/images/brand/emisar-email-lockup.png" width="153" height="40"), name
        refute html =~ ".svg", name
      end
    end

    test "carries the Gmail block and the class it keys off" do
      for {name, html} <- rendered_bodies() do
        assert html =~ Style.gmail_css(), "#{name}: no Gmail-only block"
        assert html =~ ~s(<body class="body ), "#{name}: nothing for `u + .body` to match"
      end
    end

    test "paints every surface with the gm- class that repaints its own color" do
      for {name, html} <- rendered_bodies(), tag <- painted_tags(html) do
        [color] = Regex.run(~r/background-color:(#[0-9a-f]{6})/, tag, capture: :all_but_first)
        [classes] = Regex.run(~r/class="([^"]*)"/, tag, capture: :all_but_first) || [""]
        painted = @fills |> Map.take(String.split(classes)) |> Map.values()

        assert Enum.map(painted, &apply(Style, &1, [])) == [color],
               "#{name}: #{tag} — a background-color without its own gm- class is " <>
                 "flipped to its opposite. Pair Style.fill/1 with the matching class."
      end
    end

    test "draws dividers and outlines as fills, because a border cannot be painted" do
      for {name, html} <- rendered_bodies() do
        refute html =~ ~r/border(-top|-bottom|-left|-right)?:\s*1px/,
               "#{name}: a border flips to a bright line. Use Style.rule/1, or an edge fill."

        refute html =~ "bgcolor=", "#{name}: a bgcolor flips like a background-color"
      end
    end
  end

  defp painted_tags(html) do
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
        %Accounts.Membership{display_name: "Olivia Owner", contact_email: "olivia@example.com"},
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
          {:paragraph, "A plain paragraph."},
          {:link_paragraph, "Sign in to ", "Fleet Ops", "https://emisar.dev/app", "."},
          {:emphasis, "Sent to ", "olivia@example.com", "."},
          {:status, "This action ", "needs your approval", ".", :warning},
          {:status, "It is ", "unchanged", ".", :neutral},
          {:facts, [{"Action", "linux.uptime"}, {"Account", {:link, "Fleet Ops", "https://e"}}]},
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

  # WCAG relative-luminance contrast between two `#rrggbb` colors.
  defp contrast(a, b) do
    {la, lb} = {luminance(a), luminance(b)}
    (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  end

  defp luminance(hex) do
    [r, g, b] =
      Enum.map(rgb(hex), fn c ->
        if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
      end)

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  # Gmail's rewrite: the same hue and saturation at 1 - lightness.
  defp flip(hex) do
    {h, l, s} = to_hls(rgb(hex))
    {r, g, b} = from_hls(h, 1 - l, s)
    "#" <> Enum.map_join([r, g, b], &channel_hex/1)
  end

  defp channel_hex(channel) do
    (channel * 255) |> round() |> Integer.to_string(16) |> String.pad_leading(2, "0")
  end

  defp rgb("#" <> hex) do
    for <<c::binary-size(2) <- hex>>, do: String.to_integer(c, 16) / 255
  end

  defp to_hls([r, g, b]) do
    {maxc, minc} = {Enum.max([r, g, b]), Enum.min([r, g, b])}
    l = (minc + maxc) / 2

    if maxc == minc do
      {0.0, l, 0.0}
    else
      d = maxc - minc
      s = if l <= 0.5, do: d / (maxc + minc), else: d / (2 - maxc - minc)
      {rc, gc, bc} = {(maxc - r) / d, (maxc - g) / d, (maxc - b) / d}

      h =
        cond do
          r == maxc -> bc - gc
          g == maxc -> 2 + rc - bc
          true -> 4 + gc - rc
        end

      {fmod(h / 6), l, s}
    end
  end

  defp from_hls(_h, l, s) when s == 0.0, do: {l, l, l}

  defp from_hls(h, l, s) do
    m2 = if l <= 0.5, do: l * (1 + s), else: l + s - l * s
    m1 = 2 * l - m2
    {hue(m1, m2, h + 1 / 3), hue(m1, m2, h), hue(m1, m2, h - 1 / 3)}
  end

  defp hue(m1, m2, h) do
    h = fmod(h)

    cond do
      h < 1 / 6 -> m1 + (m2 - m1) * h * 6
      h < 0.5 -> m2
      h < 2 / 3 -> m1 + (m2 - m1) * (2 / 3 - h) * 6
      true -> m1
    end
  end

  defp fmod(x), do: x - Float.floor(x / 1)
end
