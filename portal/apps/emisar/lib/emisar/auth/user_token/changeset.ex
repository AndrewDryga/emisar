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

  @doc "Single-use emailed token row (magic link / password reset / confirm)."
  def hashed(%Users.User{} = user, digest, context, sent_to)
      when is_binary(digest) and is_binary(context) do
    change(%UserToken{}, token: digest, context: context, sent_to: sent_to, user_id: user.id)
  end

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
