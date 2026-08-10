defmodule EmisarWeb.StaticImage.Header do
  @moduledoc """
  Pixel dimensions from an image's own header bytes.

  Its own module so `EmisarWeb.StaticImage` can call it while building a
  compile-time map — a private function in that module would not exist yet at
  the point the attribute is evaluated.
  """

  import Bitwise

  @doc """
  `{width, height}` from a WebP or PNG binary, or `nil` for anything else.

  WebP here is always the simple lossy `VP8 ` form our capture pipeline emits: a
  RIFF container, then a 3-byte frame tag, the 3-byte sync code, and two 14-bit
  dimensions whose top bits are a scaling hint. PNG carries them as two
  big-endian 32-bit values in IHDR, always the first chunk.
  """
  def dimensions(
        <<"RIFF", _size::binary-size(4), "WEBPVP8 ", _chunk::binary-size(4), _tag::binary-size(3),
          0x9D, 0x01, 0x2A, width::little-16, height::little-16, _rest::binary>>
      ) do
    {width &&& 0x3FFF, height &&& 0x3FFF}
  end

  # VP8X is the EXTENDED form cwebp emits whenever a file carries alpha, ICC, or
  # animation — 18 of ours do. Its canvas size is two 24-bit little-endian values
  # stored minus one, and it must be matched before nothing else claims the file:
  # missing this clause silently measured only the simple-lossy files, which the
  # coverage test in static_image_test.exs is there to catch.
  def dimensions(
        <<"RIFF", _size::binary-size(4), "WEBPVP8X", _chunk::binary-size(4),
          _flags::binary-size(4), width::little-24, height::little-24, _rest::binary>>
      ) do
    {width + 1, height + 1}
  end

  def dimensions(
        <<0x89, "PNG\r\n", 0x1A, "\n", _len::32, "IHDR", width::32, height::32, _rest::binary>>
      ) do
    {width, height}
  end

  def dimensions(binary) when is_binary(binary), do: nil
end

defmodule EmisarWeb.StaticImage do
  @moduledoc """
  Intrinsic pixel dimensions for the images we serve, read from the files
  themselves at compile time.

  An `<img>` without `width`/`height` reserves no space until the bytes decode,
  so the page reflows as each one arrives. The docs screenshots are the worst
  case for that — thirteen pages, up to eleven shots each, aspect ratios from
  1680x328 to 1680x2142 — and they are the pages that rank.

  Reading the files beats writing the numbers at each call site. There are 66 of
  those, and a recapture at a different size would silently make every hand-typed
  pair a lie; here the sizes cannot disagree with the bytes we ship. Each file is
  an `@external_resource`, so replacing a screenshot recompiles this.
  """

  alias EmisarWeb.StaticImage.Header

  @images_root Path.expand("../../priv/static/images", __DIR__)

  @paths @images_root
         |> Path.join("**/*.{webp,png}")
         |> Path.wildcard()
         |> Enum.sort()

  # Every DIRECTORY is a resource too, not just the files in it. A file-only
  # list can never notice a file that did not exist when this module was last
  # compiled, so ADDING an image left a warm build (CI restores one) reporting
  # the old count and failing the coverage test below with no way to pass short
  # of `mix compile --force`. A directory's mtime moves when an entry is added
  # or removed, so this is what makes a new capture recompile the map.
  @directories [@images_root | Path.wildcard(Path.join(@images_root, "**/"))]

  for path <- @paths ++ @directories do
    @external_resource path
  end

  @dimensions for path <- @paths,
                  measured = path |> File.read!() |> Header.dimensions(),
                  into: %{},
                  do: {"/images/" <> Path.relative_to(path, @images_root), measured}

  @doc """
  `{width, height}` for a served image path (`/images/...`), or `nil` when the
  file is not one we could measure. Callers omit the attributes on `nil` rather
  than guessing — a wrong pair is worse than none, because the browser scales the
  image to whatever it is told.
  """
  def dimensions(path), do: Map.get(@dimensions, path)

  @doc "How many served images we could measure. Used by the test that guards this."
  def measured, do: map_size(@dimensions)
end
