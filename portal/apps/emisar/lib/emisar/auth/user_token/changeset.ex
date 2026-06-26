defmodule Emisar.Auth.UserToken.Changeset do
  use Emisar, :changeset
  alias Emisar.Auth.UserToken
  alias Emisar.Users

  @doc """
  Session-cookie token row. Persists the digest (never the raw bearer) plus
  optional request metadata for the Profile sessions list. `auth_method` (how
  the session was authenticated) and `mfa` (whether a second factor was
  verified) are always-present provenance, so they're positional; `opts` carry
  the SSO-only `:user_identity_id`.
  """
  def session(%Users.User{} = user, digest, metadata, auth_method, mfa, opts \\ [])
      when is_binary(digest) and is_boolean(mfa) do
    change(%UserToken{},
      token: digest,
      context: "session",
      user_id: user.id,
      metadata: normalize_metadata(metadata),
      auth_method: auth_method,
      mfa: mfa,
      user_identity_id: Keyword.get(opts, :user_identity_id)
    )
  end

  @doc "Single-use emailed token row (password reset / confirm)."
  def hashed(%Users.User{} = user, digest, context, sent_to)
      when is_binary(digest) and is_binary(context) do
    change(%UserToken{}, token: digest, context: context, sent_to: sent_to, user_id: user.id)
  end

  @doc """
  Split-code magic-link token row. `digest` is `Crypto.hash(nonce <> secret)` —
  neither half is stored, so a DB breach + an intercepted email still can't sign
  in. `attempts` is the online-guess budget for the 6-digit secret.
  """
  def magic_link(%Users.User{} = user, digest, sent_to, attempts)
      when is_binary(digest) and is_integer(attempts) do
    change(%UserToken{},
      token: digest,
      context: "magic_link",
      sent_to: sent_to,
      user_id: user.id,
      remaining_attempts: attempts
    )
  end

  @doc """
  Email-change step-up token. A 6-digit code (only its digest is stored) is
  emailed to the user's CURRENT address; `sent_to` binds the NEW email this
  code authorizes, so a code can only confirm the exact change it was issued
  for. `attempts` caps online guessing of the code.
  """
  def email_change(%Users.User{} = user, digest, new_email, attempts)
      when is_binary(digest) and is_binary(new_email) and is_integer(attempts) do
    change(%UserToken{},
      token: digest,
      context: "email_change",
      sent_to: new_email,
      user_id: user.id,
      remaining_attempts: attempts
    )
  end

  @doc "Spend one attempt on a split-code step-up token (a wrong nonce/secret/code)."
  def decrement_attempts(%UserToken{remaining_attempts: n} = token) when is_integer(n),
    do: change(token, remaining_attempts: n - 1)

  # The request metadata arrives from Plug with mixed atom/string keys
  # and non-string values — normalize to the two string-keyed fields
  # the sessions list renders, dropping blanks.
  defp normalize_metadata(metadata) when is_map(metadata) do
    %{
      "ip_address" => to_string_or_nil(metadata[:ip_address] || metadata["ip_address"]),
      "user_agent" => to_string_or_nil(metadata[:user_agent] || metadata["user_agent"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_metadata(_), do: %{}

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value), do: to_string(value)
end
