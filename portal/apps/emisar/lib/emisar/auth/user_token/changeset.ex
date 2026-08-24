defmodule Emisar.Auth.UserToken.Changeset do
  use Emisar, :changeset
  alias Emisar.Auth.UserToken
  alias Emisar.Users

  @metadata_value_limit 255

  @doc """
  Session-cookie token row. Persists the digest (never the raw bearer) plus
  optional request metadata for the Profile sessions list. `auth_method` (how
  the session was authenticated) and `mfa_verified_at` (when a second factor was
  verified, or nil) are always-present provenance, so they're positional; `opts`
  carry the SSO-only `:user_identity_id`.
  """
  def session(%Users.User{} = user, digest, metadata, auth_method, mfa_verified_at, opts \\ [])
      when is_binary(digest) and
             (is_nil(mfa_verified_at) or is_struct(mfa_verified_at, DateTime)) do
    mfa_enrollment_verified_at =
      if auth_method == :magic_link and not is_nil(mfa_verified_at), do: user.mfa_enabled_at

    change(%UserToken{},
      token: digest,
      context: "session",
      user_id: user.id,
      metadata: normalize_metadata(metadata),
      auth_method: auth_method,
      mfa_verified_at: mfa_verified_at,
      mfa_enrollment_verified_at: mfa_enrollment_verified_at,
      user_identity_id: Keyword.get(opts, :user_identity_id)
    )
  end

  @doc "Records that this exact live session proved the current local MFA enrollment."
  def local_mfa_verified(
        %UserToken{context: "session"} = token,
        %DateTime{} = enrollment_verified_at
      ),
      do: change(token, mfa_enrollment_verified_at: enrollment_verified_at)

  @doc "Single-use emailed token row (password reset / confirm)."
  def hashed(%Users.User{} = user, digest, context, sent_to)
      when is_binary(digest) and is_binary(context) do
    change(%UserToken{}, token: digest, context: context, sent_to: sent_to, user_id: user.id)
  end

  @doc """
  Split-code magic-link token row. `digest` is `Crypto.hash(nonce <> secret)` —
  neither half is stored, so a DB breach + an intercepted email still can't sign
  in. `attempts` is the online-guess budget for the 6-character secret.
  """
  def magic_link(%Users.User{} = user, digest, sent_to, attempts, owner_registration)
      when is_binary(digest) and is_integer(attempts) do
    metadata =
      case owner_registration do
        %{account_name: account_name, full_name: full_name}
        when is_binary(account_name) and (is_binary(full_name) or is_nil(full_name)) ->
          %{
            "registration_account_name" => account_name,
            "registration_full_name" => full_name
          }

        nil ->
          %{}
      end

    change(%UserToken{},
      token: digest,
      context: "magic_link",
      sent_to: sent_to,
      user_id: user.id,
      remaining_attempts: attempts,
      metadata: metadata
    )
  end

  @doc "Promotes this exact split token into the short-lived factor final session minting consumes."
  def verified_magic_link(%UserToken{context: "magic_link"} = token, %DateTime{} = verified_at) do
    change(token,
      context: "magic_link_verified",
      metadata: Map.put(token.metadata || %{}, "verified_at", DateTime.to_iso8601(verified_at))
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

  @doc "Pending current-inbox code, promoted only after its email is accepted for delivery."
  def pending_mfa_enrollment(%Users.User{} = user, digest, attempts)
      when is_binary(digest) and is_integer(attempts) do
    change(%UserToken{},
      token: digest,
      context: "mfa_enrollment_pending",
      sent_to: user.email,
      user_id: user.id,
      remaining_attempts: attempts,
      metadata: %{"user_updated_at" => DateTime.to_iso8601(user.updated_at)}
    )
  end

  @doc "Makes a delivered current-inbox code eligible for MFA-enrollment verification."
  def activate_mfa_enrollment(%UserToken{} = token),
    do: change(token, context: "mfa_enrollment")

  @doc "Spend one attempt on a typable magic-link or credential-step-up token."
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

  defp to_string_or_nil(value) when is_binary(value),
    do: String.slice(value, 0, @metadata_value_limit)

  defp to_string_or_nil(value), do: value |> to_string() |> to_string_or_nil()
end
