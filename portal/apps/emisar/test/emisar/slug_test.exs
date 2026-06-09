defmodule Emisar.SlugTest do
  use ExUnit.Case, async: true

  alias Emisar.Slug

  describe "slugify/2" do
    test "lowercases and hyphenates" do
      assert Slug.slugify("Acme Co") == "acme-co"
    end

    test "collapses runs of non-alphanumerics to a single hyphen" do
      assert Slug.slugify("Acme   Co!!!Ltd") == "acme-co-ltd"
    end

    test "trims leading and trailing hyphens" do
      assert Slug.slugify("  !Acme!  ") == "acme"
    end

    test "caps the result at :max_length" do
      assert Slug.slugify(String.duplicate("a", 100), max_length: 10) == String.duplicate("a", 10)
    end

    test "returns :default when slugification is empty" do
      assert Slug.slugify("!!!", default: "team") == "team"
      assert Slug.slugify("", default: "team") == "team"
    end

    test "an empty result is \"\" when no :default is given" do
      assert Slug.slugify("???") == ""
    end

    test "coerces non-binary input" do
      assert Slug.slugify(nil) == ""
    end
  end
end
