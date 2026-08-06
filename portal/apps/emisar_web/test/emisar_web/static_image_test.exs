defmodule EmisarWeb.StaticImageTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.StaticImage

  describe "dimensions/1" do
    test "reads a served WebP screenshot's real size" do
      assert StaticImage.dimensions("/images/screenshots/runner-fleet.webp") == {1680, 1580}
    end

    # VP8X is the extended container cwebp emits for alpha/ICC/animation. It
    # stores its canvas size differently from the simple lossy form, and 18 of our
    # images use it — they were measured as nil until this clause existed.
    test "reads an extended (VP8X) WebP" do
      assert StaticImage.dimensions("/images/docs/sso/google-branding.webp") == {1520, 915}
    end

    test "reads a PNG" do
      assert {1200, 630} = StaticImage.dimensions("/images/og/og-pricing.png")
    end

    test "is nil for a path we do not serve" do
      assert StaticImage.dimensions("/images/nope.webp") == nil
    end

    # The point of reading the files is that every docs screenshot is covered.
    # A parser that silently returned nil for the whole set would leave the
    # component emitting no dimensions at all, which is the bug this replaces.
    test "measured every image under priv/static/images" do
      on_disk =
        Path.expand("../../priv/static/images", __DIR__)
        |> Path.join("**/*.{webp,png}")
        |> Path.wildcard()
        |> length()

      assert StaticImage.measured() == on_disk
      assert on_disk > 70
    end
  end
end
