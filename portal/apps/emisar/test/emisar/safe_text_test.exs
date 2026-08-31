defmodule Emisar.SafeTextTest do
  use ExUnit.Case, async: true
  alias Emisar.SafeText

  @rlo <<0x202E::utf8>>
  @null <<0>>

  describe "unsafe?/1" do
    test "detects control, format, and surrogate characters" do
      assert SafeText.unsafe?("db-" <> @rlo <> "prod")
      assert SafeText.unsafe?("line" <> @null)
      assert SafeText.unsafe?("tab\there")
    end

    test "ordinary text (incl. multibyte) is safe" do
      refute SafeText.unsafe?("db-prod-01")
      refute SafeText.unsafe?("café — naïve")
      refute SafeText.unsafe?("")
    end

    test "a non-binary is safe" do
      refute SafeText.unsafe?(nil)
      refute SafeText.unsafe?(42)
    end
  end

  describe "strip/1" do
    test "removes the offending characters and keeps the rest" do
      assert SafeText.strip("db-" <> @rlo <> "prod") == "db-prod"
      assert SafeText.strip("keep" <> @null) == "keep"
      refute SafeText.unsafe?(SafeText.strip("a" <> @rlo <> "b" <> @null))
    end
  end

  describe "unsafe_multiline?/1" do
    test "line breaks and tabs are safe" do
      refute SafeText.unsafe_multiline?("line1\nline2")
      refute SafeText.unsafe_multiline?("a\tb")
      refute SafeText.unsafe_multiline?("a\r\nb")
    end

    test "every other control, format, or surrogate character is still unsafe" do
      assert SafeText.unsafe_multiline?("safe" <> @rlo <> "evil")
      assert SafeText.unsafe_multiline?("a" <> @null <> "b")
      assert SafeText.unsafe_multiline?("a\e[31mb")
    end

    test "a non-binary is safe" do
      refute SafeText.unsafe_multiline?(nil)
    end
  end

  describe "strip_multiline/1" do
    test "keeps the layout and drops the deception surface" do
      assert SafeText.strip_multiline("line1\nline2\tend") == "line1\nline2\tend"
      assert SafeText.strip_multiline("safe" <> @rlo <> "evil") == "safeevil"
      assert SafeText.strip_multiline("a" <> @null <> "b") == "ab"
      refute SafeText.unsafe_multiline?(SafeText.strip_multiline("x" <> @rlo <> "\n" <> @null))
    end
  end
end
