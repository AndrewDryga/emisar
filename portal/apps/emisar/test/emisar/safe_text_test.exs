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
end
