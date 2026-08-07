defmodule Emisar.CanonicalJSONTest do
  @moduledoc """
  The canonical encoding behind two identity digests that
  `.agent/kb/specs/compatibility.md` freezes at 1.0: the action-contract hash a
  client compares to decide `target_contract_changed`, and a runbook's
  `definition_hash`.

  Both were computed by byte-identical private copies in two modules. The
  agreement tests below are what let those copies collapse into one — a peer
  compares the two values, so a divergence would surface as a false "contract
  changed" rather than a failing test.
  """
  use ExUnit.Case, async: true
  alias Emisar.ActionContract
  alias Emisar.CanonicalJSON
  alias Emisar.Runbooks.Definition

  # Shapes chosen for the ways a canonicaliser can differ: key order, nesting,
  # list position, empty containers, every scalar type, and escaping.
  @samples [
    %{"b" => 1, "a" => 2},
    %{"z" => %{"y" => [3, 1, 2], "x" => "s"}, "a" => nil},
    %{"list" => [%{"b" => 1, "a" => 2}, %{"d" => 4, "c" => 3}]},
    %{"n" => 1.5, "t" => true, "f" => false, "nul" => nil, "e" => %{}, "el" => []},
    %{"unicode" => "café ✓", "esc" => "a\"b\\c\nd"},
    %{"deep" => %{"a" => %{"b" => %{"c" => %{"d" => [1, %{"z" => 0, "y" => 1}]}}}}}
  ]

  describe "encode!/1" do
    test "orders object keys and leaves list position alone" do
      assert CanonicalJSON.encode!(%{"b" => 1, "a" => 2}) == ~s({"a":2,"b":1})
      assert CanonicalJSON.encode!(%{"l" => [3, 1, 2]}) == ~s({"l":[3,1,2]})
    end

    test "orders nested objects at every depth, including inside lists" do
      value = %{"z" => %{"b" => 1, "a" => 2}, "l" => [%{"d" => 1, "c" => 2}]}
      assert CanonicalJSON.encode!(value) == ~s({"l":[{"c":2,"d":1}],"z":{"a":2,"b":1}})
    end

    test "two maps differing only in insertion order encode identically" do
      assert CanonicalJSON.encode!(%{"a" => 1, "b" => 2}) ==
               CanonicalJSON.encode!(%{"b" => 2, "a" => 1})
    end
  end

  describe "digest/1" do
    test "is the hex SHA-256 of the canonical text" do
      value = %{"a" => 1}
      assert CanonicalJSON.digest(value) == Emisar.Crypto.hash_hex(CanonicalJSON.encode!(value))
    end

    test "a key-order-only difference does not change the digest" do
      assert CanonicalJSON.digest(%{"a" => 1, "b" => 2}) ==
               CanonicalJSON.digest(%{"b" => 2, "a" => 1})
    end

    test "a value difference does change it" do
      refute CanonicalJSON.digest(%{"a" => 1}) == CanonicalJSON.digest(%{"a" => 2})
    end
  end

  # The point of the module: both frozen digests must be this one function.
  describe "the two frozen identity digests" do
    for {sample, index} <- Enum.with_index(@samples) do
      test "sample #{index}: action-contract and runbook-definition digests agree with it" do
        sample = unquote(Macro.escape(sample))
        shared = CanonicalJSON.digest(sample)

        assert ActionContract.digest(sample) == shared
        assert Definition.digest(sample) == shared
      end
    end
  end
end
