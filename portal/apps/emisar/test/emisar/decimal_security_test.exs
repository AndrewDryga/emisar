defmodule Emisar.DecimalSecurityTest do
  use ExUnit.Case, async: true

  # The version-specific Hex exception in the umbrella project is justified
  # by these resource limits, not by an assumption that decimal input is trusted.
  test "parsing and casting reject pathological exponents" do
    for input <- ["1e1000000000", "1e-1000000000"] do
      assert Decimal.parse(input) == :error
      assert Decimal.cast(input) == :error
      assert_raise Decimal.Error, fn -> Decimal.new(input) end
    end

    assert {%Decimal{coef: 125, exp: -2}, ""} = Decimal.parse("1.25")
  end

  test "normal formatting rejects a compact value that would expand without bound" do
    # Still exceeds the 6,178-digit output limit, but stays safe even if a
    # future regression removes the bound and this assertion fails.
    for exponent <- [10_000, -10_000] do
      decimal = %Decimal{coef: 1, exp: exponent, sign: 1}

      assert_raise ArgumentError, fn -> Decimal.to_string(decimal, :normal) end
    end

    assert Decimal.to_string(Decimal.new("1.25"), :normal) == "1.25"
  end
end
