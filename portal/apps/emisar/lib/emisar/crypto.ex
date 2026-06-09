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
  Opaque secret for a membership invitation link — carried in the invite
  URL and matched back on acceptance. Defined here so the token's length
  and encoding stay a crypto concern, not the inviting context's.
  """
  def user_invite_token, do: random_secret(@invite_token_bytes)

  @doc """
  sha256 of a raw secret, as a 32-byte binary — the at-rest form. Store
  this, never the raw secret.
  """
  def hash(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw)

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
