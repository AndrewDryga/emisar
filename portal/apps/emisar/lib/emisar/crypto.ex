defmodule Emisar.Crypto do
  @moduledoc """
  The single home for the portal's opaque-token-secret mechanism. Every
  bearer credential — MCP API keys (`emk-`), runner enrollment keys
  (`emkey-enroll-`), per-runner tokens (`rnrtok-`), and OAuth access /
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

  # Salt namespacing the monthly-report unsubscribe signature.
  @monthly_report_unsubscribe_salt "monthly report unsubscribe"

  @doc """
  A signed, account-scoped monthly-report unsubscribe token for an emailed
  `List-Unsubscribe` link. Unlike the stored single-use `email_token/0`, this is
  **stateless** — the account id rides inside a `Phoenix.Token` MAC, so no digest
  is stored and there's nothing to revoke; it only ever flips one notification
  preference. The link never expires (a months-old email must still unsubscribe).
  Verify with `verify_monthly_report_unsubscribe_token/1`.
  """
  def monthly_report_unsubscribe_token(account_id) when is_binary(account_id),
    do: Phoenix.Token.sign(email_link_secret(), @monthly_report_unsubscribe_salt, account_id)

  @doc """
  Verifies a monthly-report unsubscribe token, returning `{:ok, account_id}` or
  `{:error, :invalid}` on a forged/mangled token. Signature-only (no expiry).
  """
  def verify_monthly_report_unsubscribe_token(token) when is_binary(token) do
    case Phoenix.Token.verify(email_link_secret(), @monthly_report_unsubscribe_salt, token,
           max_age: :infinity
         ) do
      {:ok, account_id} -> {:ok, account_id}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  defp email_link_secret, do: Application.fetch_env!(:emisar, :email_link_secret)

  # The emailed magic-link secret is a short, typable code; the browser-side
  # nonce carries the entropy, so a 6-char code + the attempt cap is safe (an
  # email interceptor lacks the nonce and gets @magic_link_attempts guesses).
  @code_length 6

  # Unambiguous uppercase alphabet for the typed sign-in code — no 0/O, 1/I/L,
  # or U, each a read/type look-alike. 30 symbols, so a 6-char code spans
  # 30^6 ≈ 7.3e8 values (vs 10^6 for digits) — a wider space to guess, though
  # the nonce is still what makes the code secure. Letters are what buys the
  # extra space and keep the code short enough to type by hand.
  @code_alphabet ~c"23456789ABCDEFGHJKMNPQRSTVWXYZ"

  @doc """
  Mints a split-code magic-link token as `{nonce, secret, digest}`. The
  high-entropy `nonce` stays in the browser, the short alphanumeric `secret` is
  emailed (and typable cross-device), and only `digest = hash(nonce <> secret)`
  is stored — neither half alone reconstructs it, so a DB breach plus an
  intercepted email still can't sign in. Verify with `magic_link_digest/2`.
  """
  def magic_link_token do
    nonce = random_secret()
    secret = typable_code(@code_length)
    {nonce, secret, hash(nonce <> secret)}
  end

  @doc "Digest of a presented `(nonce, secret)` pair, for the magic-link row compare."
  def magic_link_digest(nonce, secret) when is_binary(nonce) and is_binary(secret),
    do: hash(nonce <> secret)

  @doc """
  Mints an email-change step-up code as `{code, digest}` — a 6-digit code
  emailed to the user's CURRENT address to re-prove control before the
  identity-defining email is changed. Only `digest = hash(code)` is stored.
  Unlike the magic link there's no browser nonce: the authenticated session
  IS the second factor, so the code stands alone, and a tight attempts budget
  plus a short expiry bound online guessing.
  """
  def email_change_code do
    code = numeric_code(@code_length)
    {code, hash(code)}
  end

  # Crypto-random zero-padded N-digit code. 8 random bytes mod 10^N — the
  # modulo bias over 64 bits is ~5e-14, negligible for a code whose security
  # is the nonce, not its own entropy.
  defp numeric_code(digits) when is_integer(digits) and digits > 0 do
    max = Integer.pow(10, digits)

    :crypto.strong_rand_bytes(8)
    |> :binary.decode_unsigned()
    |> rem(max)
    |> Integer.to_string()
    |> String.pad_leading(digits, "0")
  end

  # Crypto-random N-char code over @code_alphabet: reduce 64 random bits into the
  # code space (30^N), then base-convert. The reduction's modulo bias over 64
  # bits is ~1e-10 (same shape as numeric_code), negligible for a code whose
  # security is the nonce and the attempt cap.
  defp typable_code(length) when is_integer(length) and length > 0 do
    base = length(@code_alphabet)

    :crypto.strong_rand_bytes(8)
    |> :binary.decode_unsigned()
    |> rem(Integer.pow(base, length))
    |> encode_code(base, length, [])
  end

  defp encode_code(_n, _base, 0, acc), do: List.to_string(acc)

  defp encode_code(n, base, remaining, acc) do
    encode_code(div(n, base), base, remaining - 1, [Enum.at(@code_alphabet, rem(n, base)) | acc])
  end

  @device_user_code_length 8

  @doc """
  The MCP device-grant poll credential — the long secret the installer holds
  and presents on each poll. Returns `{code, digest}`; only the digest is
  stored, for the grant-row lookup.
  """
  def mcp_device_code do
    code = "emdg-" <> random_secret()
    {code, mcp_device_code_digest(code)}
  end

  @doc "Digest of a presented device code, for the grant-row lookup."
  def mcp_device_code_digest(raw) when is_binary(raw), do: encode_digest(hash(raw))

  @doc """
  The short human approval code the installer prints and the operator enters
  (or clicks) in the portal — #{@device_user_code_length} chars over the
  unambiguous alphabet, shown `XXXX-XXXX` (30^8 ≈ 2^39 values, paired with a
  short expiry and rate-limited entry). Returns `{code, digest}`.
  """
  def mcp_device_user_code do
    code = typable_code(@device_user_code_length)
    formatted = String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)
    {formatted, mcp_device_user_code_digest(formatted)}
  end

  @doc """
  Digest of a presented device-grant user code for the pending-grant lookup —
  normalizes case, separators, and whitespace first so `fkzq 2418` and
  `FKZQ-2418` digest identically.
  """
  def mcp_device_user_code_digest(raw) when is_binary(raw) do
    raw
    |> String.upcase()
    |> String.replace(~r/[\s-]/, "")
    |> hash()
    |> encode_digest()
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

  @doc """
  A cookieless, per-week anonymous visitor id — `hash_hex/1` of a request
  fingerprint (IP + User-Agent) keyed by the app secret AND the start of the
  current UTC week. The week rotates the id every Monday, so a visitor is
  countable within a week (good for weekly-active + retention) but UNLINKABLE
  across weeks: no persistent identifier and no cookie (the Plausible/Fathom
  privacy model). The secret salt stops anyone without it from recomputing a
  week's ids from a guessed fingerprint. Used as the `$device:` id for anonymous
  analytics events; identified users are tracked by their user id.
  """
  def anonymous_visitor_id(fingerprint) when is_binary(fingerprint) do
    salt = Application.fetch_env!(:emisar, :analytics_salt)
    week_start = Date.to_iso8601(Date.beginning_of_week(Date.utc_today()))
    hash_hex(salt <> "|" <> week_start <> "|" <> fingerprint)
  end

  # Dispatch correlation ids ride in runner envelopes, results, and logs;
  # 16 random bytes keeps them unguessable without bloating log lines.
  @request_id_bytes 16

  @request_id_pattern ~r/\Areq_[A-Za-z0-9_-]{22}\z/

  @doc "Correlation id for one action dispatch (`req_…`)."
  def run_request_id, do: "req_" <> random_secret(@request_id_bytes)

  @doc "Whether a value is a canonical action-dispatch correlation id."
  def valid_run_request_id?(value) when is_binary(value),
    do: Regex.match?(@request_id_pattern, value)

  def valid_run_request_id?(_value), do: false

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
  prefix (API keys, runner enrollment keys, runner tokens).

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
