defmodule Emisar.CryptoTest do
  use ExUnit.Case, async: true

  alias Emisar.Crypto

  describe "random_secret/1" do
    test "is url-safe base64 of 32 bytes by default, and unique per call" do
      a = Crypto.random_secret()
      b = Crypto.random_secret()

      refute a == b
      assert {:ok, raw} = Base.url_decode64(a, padding: false)
      assert byte_size(raw) == 32
      # url-safe alphabet only (no +, /, or padding)
      assert a =~ ~r/\A[A-Za-z0-9_-]+\z/
    end

    test "honours a custom byte count" do
      assert {:ok, raw} = Base.url_decode64(Crypto.random_secret(16), padding: false)
      assert byte_size(raw) == 16
    end
  end

  describe "hash/1" do
    test "is a deterministic 32-byte sha256 that varies with input" do
      assert Crypto.hash("emk-abc") == Crypto.hash("emk-abc")
      assert byte_size(Crypto.hash("emk-abc")) == 32
      refute Crypto.hash("emk-abc") == Crypto.hash("emk-abd")
      assert Crypto.hash("emk-abc") == :crypto.hash(:sha256, "emk-abc")
    end
  end

  describe "mint/2" do
    test "returns {raw, lookup_prefix, hash} with the tag and exact prefix length" do
      {raw, prefix, hash} = Crypto.mint("emk-", 12)

      assert String.starts_with?(raw, "emk-")
      assert prefix == String.slice(raw, 0, 12)
      assert String.length(prefix) == 12
      assert hash == Crypto.hash(raw)
    end

    test "preserves each credential type's prefix length" do
      assert {_, p, _} = Crypto.mint("emkey-auth-", 27)
      assert String.length(p) == 27 and String.starts_with?(p, "emkey-auth-")

      assert {_, q, _} = Crypto.mint("rnrtok-", 12)
      assert String.length(q) == 12 and String.starts_with?(q, "rnrtok-")
    end

    test "two mints of the same type are distinct secrets" do
      {raw1, pfx1, h1} = Crypto.mint("emk-", 12)
      {raw2, pfx2, h2} = Crypto.mint("emk-", 12)

      refute raw1 == raw2
      refute h1 == h2
      # The 4-char tag is shared; the random tail in the prefix is not.
      refute pfx1 == pfx2
    end

    test "rejects a prefix_size not larger than the tag" do
      assert_raise FunctionClauseError, fn -> Crypto.mint("emk-", 4) end
    end
  end

  describe "secure_compare/2" do
    test "true for equal binaries, false for different or mismatched sizes" do
      h = Crypto.hash("secret")
      assert Crypto.secure_compare(h, h)
      assert Crypto.secure_compare(<<1, 2, 3>>, <<1, 2, 3>>)
      refute Crypto.secure_compare(h, Crypto.hash("other"))
      # length mismatch must be false, never raise
      refute Crypto.secure_compare(<<1, 2, 3>>, <<1, 2>>)
      refute Crypto.secure_compare("x", :not_a_binary)
    end
  end
end
