defmodule Emisar.Mailers.StyleTest do
  @moduledoc """
  The Gmail apps ignore `color-scheme` and rewrite every authored color by
  flipping its HSL lightness, so a dark email reaches a dark-theme Gmail reader
  as a light one. The palette survives that by construction: every ink clears
  4.5:1 on both grounds as authored and after the flip, and the lockup is a
  raster on its own ground, which a rewrite never touches.
  """
  use ExUnit.Case, async: true
  alias Emisar.Mailers.Style

  @inks [:ink, :ink_soft, :brand, :rose, :amber]
  @grounds [:ground, :surface]

  test "every ink clears 4.5:1 on both grounds, as authored and after Gmail's lightness flip" do
    for ink <- @inks, ground <- @grounds do
      fg = apply(Style, ink, [])
      bg = apply(Style, ground, [])

      assert contrast(fg, bg) >= 4.5, "#{ink} on #{ground} as authored: #{contrast(fg, bg)}"

      assert contrast(flip(fg), flip(bg)) >= 4.5,
             "#{ink} on #{ground} after the flip: #{contrast(flip(fg), flip(bg))}"
    end

    assert contrast(Style.ground(), Style.brand()) >= 4.5
    assert contrast(flip(Style.ground()), flip(Style.brand())) >= 4.5
  end

  test "the document declares the dark scheme and the masthead is a raster on its ground" do
    html = Style.document("Title", "Preview", 560, Style.masthead())

    assert html =~ ~s(<meta name="color-scheme" content="dark" />)
    assert html =~ ~s(<meta name="supported-color-schemes" content="dark" />)
    assert html =~ "color-scheme: dark; supported-color-schemes: dark;"
    assert html =~ ~s(/images/brand/emisar-email-lockup.png" width="153" height="40")
    refute html =~ ".svg"
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
