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

    test "is never padded" do
      refute Crypto.random_secret() =~ "="
    end
  end

  describe "email_token/0 + email_token_digest/1" do
    test "the emitted token re-derives its stored digest" do
      {encoded, digest} = Crypto.email_token()

      assert {:ok, ^digest} = Crypto.email_token_digest(encoded)
      # url-safe alphabet only — it rides in a URL.
      assert encoded =~ ~r/\A[A-Za-z0-9_-]+\z/
    end

    test "a non-base64 presented token is :error, not a crash or false match" do
      assert :error = Crypto.email_token_digest("not valid base64 !!!")
    end
  end

  describe "user_invite_token/0 + user_invite_token_digest/1" do
    test "returns a URL-safe token whose digest can be re-derived" do
      {raw, digest} = Crypto.user_invite_token()

      assert raw =~ ~r/\A[A-Za-z0-9_-]+\z/
      assert digest == Crypto.user_invite_token_digest(raw)
    end
  end

  describe "session_token/0" do
    test "returns 32 raw bytes and their at-rest digest" do
      {raw, digest} = Crypto.session_token()

      assert byte_size(raw) == 32
      assert digest == Crypto.hash(raw)
    end
  end

  describe "magic_link_token/0" do
    test "the emailed secret is a 6-char code from the unambiguous alphabet" do
      {_nonce, secret, _digest} = Crypto.magic_link_token()

      # Uppercase alphanumeric, 6 chars, and none of the read/type look-alikes
      # (0/O, 1/I/L, U) — that's what makes it typable by hand.
      assert String.length(secret) == 6
      assert secret =~ ~r/^[0-9A-Z]{6}$/
      refute secret =~ ~r/[01ILOU]/
    end

    test "digest binds the (nonce, secret) pair — neither half alone reconstructs it" do
      {nonce, secret, digest} = Crypto.magic_link_token()

      assert digest == Crypto.magic_link_digest(nonce, secret)
      refute digest == Crypto.magic_link_digest(nonce, "WRONG2")
      refute digest == Crypto.magic_link_digest("wrong-nonce", secret)
    end

    test "two tokens differ (fresh randomness each mint)" do
      {_, a, _} = Crypto.magic_link_token()
      {_, b, _} = Crypto.magic_link_token()
      # 30^6 space — a collision here would be a broken RNG, not bad luck.
      refute a == b
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

  describe "hash_hex/1" do
    test "is lowercase-hex sha256 matching the runner-reported digest form" do
      assert Crypto.hash_hex("output payload") ==
               Base.encode16(Crypto.hash("output payload"), case: :lower)

      assert Crypto.hash_hex("x") =~ ~r/\A[0-9a-f]{64}\z/
    end
  end

  describe "email_change_code/0" do
    test "returns a six-digit code and its digest" do
      {code, digest} = Crypto.email_change_code()

      assert code =~ ~r/\A\d{6}\z/
      assert digest == Crypto.hash(code)
    end
  end

  describe "anonymous_visitor_id/1" do
    test "is a stable 64-char hex id for the same fingerprint within a week" do
      fingerprint = "203.0.113.7|Mozilla/5.0 Chrome/120"
      id = Crypto.anonymous_visitor_id(fingerprint)

      assert id == Crypto.anonymous_visitor_id(fingerprint)
      assert id =~ ~r/^[a-f0-9]{64}$/
    end

    test "differs for a different fingerprint (distinct visitors don't collide)" do
      refute Crypto.anonymous_visitor_id("1.1.1.1|UA") ==
               Crypto.anonymous_visitor_id("2.2.2.2|UA")
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

    test "the named per-credential minters produce distinct namespaces" do
      {scim_raw, scim_prefix, scim_hash} = Crypto.scim_token()
      assert String.starts_with?(scim_prefix, "ems-")
      assert String.length(scim_prefix) == Crypto.scim_token_prefix_size()
      assert scim_prefix == String.slice(scim_raw, 0, Crypto.scim_token_prefix_size())
      assert scim_hash == Crypto.hash(scim_raw)

      assert String.starts_with?(Crypto.run_request_id(), "req_")
      assert String.starts_with?(Crypto.scim_token_namespace(), "ems-")
      tags = ["emk-", "emkey-auth-", "rnrtok-", "ems-", "req_"]
      assert tags == Enum.uniq(tags)
    end
  end

  describe "OIDC and dispatch credentials" do
    test "use fixed prefixes and PKCE's S256 transform" do
      assert Crypto.run_request_id() =~ ~r/\Areq_[A-Za-z0-9_-]+\z/
      assert Crypto.runner_name_suffix() =~ ~r/\A[A-Za-z0-9_-]+\z/
      assert Crypto.oidc_state() =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert Crypto.oidc_nonce() =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert Crypto.pkce_verifier() =~ ~r/\A[A-Za-z0-9_-]{86}\z/

      verifier = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"

      assert Crypto.pkce_s256_challenge(verifier) ==
               Base.url_encode64(Crypto.hash(verifier), padding: false)
    end
  end

  describe "mfa_recovery_code/0" do
    test "is lowercased base32, unique, with a matching digest" do
      {plain1, digest1} = Crypto.mfa_recovery_code()
      {plain2, _digest2} = Crypto.mfa_recovery_code()

      assert plain1 =~ ~r/\A[a-z2-7]+\z/
      assert plain1 == String.downcase(plain1)
      refute plain1 == plain2
      assert digest1 == Crypto.hash(plain1)
    end
  end

  describe "valid_totp?/2" do
    # replay defense is the CALLER's, not Crypto's: the
    # same code validates as many times as it's presented within its window.
    # Crypto only answers "is this a currently-valid code"; the stamped-bucket
    # replay guard lives in Users.verify_and_consume_mfa under a row lock.
    test "accepts the same code repeatedly — no replay guard here" do
      secret = Crypto.totp_secret()
      code = NimbleTOTP.verification_code(secret)

      assert Crypto.valid_totp?(secret, code)
      assert Crypto.valid_totp?(secret, code)
      refute Crypto.valid_totp?(secret, "000000")
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
