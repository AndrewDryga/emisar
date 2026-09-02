defmodule Emisar.Mailers.StyleTest do
  use ExUnit.Case, async: true
  alias Emisar.Mailers.Style

  # Grounds are compared against, never drawn on; a hairline is a separator and
  # is deliberately below text contrast. Everything else in Style that returns a
  # color is ink, and has to clear the bar in both renderings.
  @grounds [:ground, :surface]
  @chrome [:hairline, :button_fill]

  describe "the palette" do
    test "every ink clears 4.5:1 on both grounds, as authored and after a client mirrors it" do
      for ink <- ink_tokens(), ground <- @grounds do
        color = apply(Style, ink, [])
        bg = apply(Style, ground, [])

        assert contrast(color, bg) >= 4.5,
               "#{ink} (#{color}) on #{ground} (#{bg}) is #{contrast(color, bg)}:1"

        assert contrast(mirror(color), mirror(bg)) >= 4.5,
               "#{ink} mirrors to #{mirror(color)} on #{mirror(bg)}, " <>
                 "which is #{contrast(mirror(color), mirror(bg))}:1"
      end
    end

    test "the button's label clears 4.5:1 on its fill, mirrored too" do
      assert contrast(Style.ink(), Style.button_fill()) >= 4.5
      assert contrast(mirror(Style.ink()), mirror(Style.button_fill())) >= 4.5
    end
  end

  defp ink_tokens do
    tokens =
      for {name, 0} <- Style.__info__(:functions),
          name not in @grounds and name not in @chrome,
          match?("#" <> <<_::binary-size(6)>>, apply(Style, name, [])),
          do: name

    # A new color token is covered by the test above the moment it is added; an
    # empty list would mean the reflection stopped finding any of them.
    assert tokens != []
    tokens
  end

  # Gmail's mobile dark theme rewrites an authored color by flipping its HSL
  # lightness and keeping hue and saturation.
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
