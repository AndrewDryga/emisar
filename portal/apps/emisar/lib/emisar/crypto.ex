defmodule Emisar.Crypto do
  @moduledoc """
  The single home for the portal's opaque-token-secret mechanism. Every
  bearer credential — MCP API keys (`emk-`), runner auth keys
  (`emkey-auth-`), per-runner tokens (`rnrtok-`), and OAuth access /
  refresh / authorization-code secrets (`emo-` / `emor-` / `emoc-`) — is
  minted, hashed, and compared here, so there is one place to audit the
  RNG, the encoding, and the hash algorithm.

  The contract every caller follows: mint a `prefix <> random_secret()`,
  hand the raw secret to the operator exactly once, and persist only its
  `hash/1` (plus, for the keys shown in the UI, a lookup prefix). The raw
  secret is never stored or logged; verification re-hashes the presented
  secret and `secure_compare/2`s it against the stored hash.
  """

  # Number of random bytes behind every secret's url-safe-base64 tail.
  @secret_bytes 32

  @doc """
  A fresh random secret string (url-safe base64, no padding). Prepend a
  type tag (e.g. `"emo-"`) to form the full token, then store its `hash/1`.
  OAuth uses this directly (it looks tokens up by hash, with no prefix
  column); prefix-looked-up credentials use `mint/2` instead.
  """
  def random_secret(bytes \\ @secret_bytes) when is_integer(bytes) and bytes > 0,
    do: :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)

  # Invitation links carry a 24-byte (192-bit) opaque token in the URL.
  @invite_token_bytes 24

  @doc """
  Opaque secret for a membership invitation link as `{raw, digest}` —
  the raw rides only in the emailed URL; persist the digest (url-safe
  string form, sized for a varchar column) and look the presented token
  up via `user_invite_token_digest/1`. Same mint→hash contract as every
  other bearer credential.
  """
  def user_invite_token do
    raw = random_secret(@invite_token_bytes)
    {raw, user_invite_token_digest(raw)}
  end

  @doc "Digest of a presented invitation token, for the row lookup."
  def user_invite_token_digest(raw) when is_binary(raw), do: encode_digest(hash(raw))

  @doc """
  Opaque session-cookie token as `{raw, digest}` — the raw bytes ride
  in the signed session cookie, only the digest is stored. Look the row
  up by `hash/1` of the presented cookie value.
  """
  def session_token do
    raw = :crypto.strong_rand_bytes(@secret_bytes)
    {raw, hash(raw)}
  end

  @doc """
  Single-use emailed token (magic link / password reset / confirm) as
  `{encoded, digest}` — the url-safe-base64 string goes in the emailed
  link, only the digest is stored. Verify a presented token with
  `email_token_digest/1`.
  """
  def email_token do
    raw = :crypto.strong_rand_bytes(@secret_bytes)
    {Base.url_encode64(raw, padding: false), hash(raw)}
  end

  @doc """
  Digest of a presented emailed token: decodes the url-safe form and
  re-hashes it for the row lookup. `:error` when the presented string
  isn't valid base64 (mangled or forged link).
  """
  def email_token_digest(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} -> {:ok, hash(raw)}
      :error -> :error
    end
  end

  @doc """
  Url-safe-base64 (no padding) of a digest — for embedding a digest in
  a PubSub topic or similar identifier without the call site inlining
  the encoding (same single-surface rule as `pkce_s256_challenge/1`).
  """
  def encode_digest(digest) when is_binary(digest),
    do: Base.url_encode64(digest, padding: false)

  @doc """
  sha256 of a raw secret, as a 32-byte binary — the at-rest form. Store
  this, never the raw secret.
  """
  def hash(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw)

  @doc """
  Lowercase-hex sha256 — the integrity-digest form for content-addressing
  non-secret payloads (run args, output digests), matching the hex
  digests runners report.
  """
  def hash_hex(raw) when is_binary(raw), do: hash(raw) |> Base.encode16(case: :lower)

  # Dispatch correlation ids ride in runner envelopes, results, and logs;
  # 16 random bytes keeps them unguessable without bloating log lines.
  @request_id_bytes 16

  @doc "Correlation id for one action dispatch (`req_…`)."
  def run_request_id, do: "req_" <> random_secret(@request_id_bytes)

  # Auto-generated runner names only need to avoid casual collision (the
  # partial unique index on the name is the real guarantee), so a short
  # tail keeps them readable.
  @runner_name_suffix_bytes 4

  @doc "Random tail for an auto-generated runner name (`runner-…`)."
  def runner_name_suffix, do: random_secret(@runner_name_suffix_bytes)

  @doc """
  PKCE S256 challenge transform (RFC 7636): the url-safe-base64 (no
  padding) encoding of `hash/1`. Lives here so the OAuth context never
  inlines `Base.url_encode64` over a digest itself — same single crypto
  review surface as every other secret transform.
  """
  def pkce_s256_challenge(verifier) when is_binary(verifier),
    do: hash(verifier) |> Base.url_encode64(padding: false)

  @doc """
  OIDC relying-party login transaction secrets, minted here so the SSO
  wrapper never inlines a byte length: `oidc_state/0` (CSRF), `oidc_nonce/0`
  (ID-token replay), and `pkce_verifier/0` (the PKCE code_verifier — 64 random
  bytes ≈ 86 url-safe chars, within RFC 7636's 43–128).
  """
  def oidc_state, do: random_secret()
  def oidc_nonce, do: random_secret()
  def pkce_verifier, do: random_secret(64)

  @doc """
  Mint a prefixed bearer secret for a credential looked up by a visible
  prefix (API keys, runner auth keys, runner tokens).

    * `prefix`      — the human-readable type tag, e.g. `"emk-"`.
    * `prefix_size` — total length of the stored lookup prefix (the tag
      plus its leading random characters), e.g. `12` for `"emk-"` + 8.

  Returns `{raw, lookup_prefix, hash}`: hand `raw` to the operator once,
  store `lookup_prefix` (for by-prefix lookup + UI display) and `hash`.
  """
  def mint(prefix, prefix_size)
      when is_binary(prefix) and is_integer(prefix_size) and prefix_size > byte_size(prefix) do
    raw = prefix <> random_secret()
    {raw, String.slice(raw, 0, prefix_size), hash(raw)}
  end

  # Per-provider SCIM bearer credential (`ems-` = emisar-scim), an
  # admin-grade token that can provision/deprovision a whole account — same
  # 12-char prefix lookup as the MCP API keys (`emk-`).
  @scim_token_namespace "ems-"
  @scim_token_prefix_size 12

  @doc """
  Mint a per-provider SCIM bearer token as `{raw, lookup_prefix, hash}`.
  Hand `raw` to the operator once; store `lookup_prefix` + `hash`.
  """
  def scim_token, do: mint(@scim_token_namespace, @scim_token_prefix_size)

  @doc "Length of the stored SCIM-token lookup prefix — the slice taken from a presented bearer."
  def scim_token_prefix_size, do: @scim_token_prefix_size

  @doc "The SCIM-token namespace tag (`ems-`) — lets a presented bearer be recognized without a scheme."
  def scim_token_namespace, do: @scim_token_namespace

  # 80-bit base32 recovery codes match the GitHub / Google Workspace
  # shape: unguessable, yet short enough to copy by hand.
  @mfa_recovery_code_bytes 10

  @doc """
  One MFA recovery code as `{plaintext, digest}` — show the plaintext
  exactly once, persist only the digest. Lowercased base32 so the code
  survives hand transcription.
  """
  def mfa_recovery_code do
    plain =
      :crypto.strong_rand_bytes(@mfa_recovery_code_bytes)
      |> Base.encode32(padding: false)
      |> String.downcase()

    {plain, hash(plain)}
  end

  @doc """
  Fresh TOTP secret for MFA enrollment. Wraps `NimbleTOTP` so the one
  crypto-review surface owns the authenticator primitive too — contexts
  never call `NimbleTOTP` directly.
  """
  def totp_secret, do: NimbleTOTP.secret()

  @doc """
  Whether `otp` is a currently-valid TOTP for `secret`. No replay guard
  — that's the caller's stamped-bucket check
  (`Users.verify_and_consume_mfa/3`, judged under the row lock).
  """
  def valid_totp?(secret, otp) when is_binary(secret) and is_binary(otp),
    do: NimbleTOTP.valid?(secret, otp)

  @doc """
  Constant-time binary comparison. False when sizes differ — `:crypto.hash_equals/2`
  requires equal-length binaries. Use this anywhere a presented secret
  is compared against a stored hash.
  """
  def secure_compare(a, b)
      when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
      do: :crypto.hash_equals(a, b)

  def secure_compare(_, _), do: false
end
