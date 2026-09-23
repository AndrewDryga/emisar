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

    proved_at = DateTime.utc_now()
    expires_at = UserToken.Query.session_expires_at(proved_at)

    change(%UserToken{},
      token: digest,
      context: "session",
      user_id: user.id,
      metadata: normalize_metadata(metadata),
      auth_method: auth_method,
      mfa_verified_at: mfa_verified_at,
      mfa_enrollment_verified_at: mfa_enrollment_verified_at,
      local_mfa_expires_at: if(mfa_enrollment_verified_at, do: expires_at),
      personal_proved_at: if(auth_method == :magic_link, do: proved_at),
      personal_expires_at: if(auth_method == :magic_link, do: expires_at),
      user_identity_id: Keyword.get(opts, :user_identity_id)
    )
  end

  @doc """
  Member-only SSO session for a workspace Member without a personal login. It
  proves one exact SSO identity and never carries personal or local-factor
  proof; `mfa_verified_at` is the IdP assurance at authentication time.
  """
  def member_session(digest, metadata, mfa_verified_at, identity_id)
      when is_binary(digest) and is_binary(identity_id) and
             (is_nil(mfa_verified_at) or is_struct(mfa_verified_at, DateTime)) do
    change(%UserToken{},
      token: digest,
      context: "session",
      metadata: normalize_metadata(metadata),
      auth_method: :sso,
      mfa_verified_at: mfa_verified_at,
      user_identity_id: identity_id
    )
    |> check_constraint(:user_id, name: :auth_user_tokens_member_only_session_check)
  end

  @doc "Records that this exact live session proved the current local MFA enrollment."
  def local_mfa_verified(
        %UserToken{context: "session"} = token,
        %DateTime{} = enrollment_verified_at
      ) do
    change(token,
      mfa_enrollment_verified_at: enrollment_verified_at,
      local_mfa_expires_at: UserToken.Query.session_expires_at(DateTime.utc_now())
    )
  end

  @doc "Rotate after SSO proof without renewing the donor's personal or local-factor evidence."
  def sso_step_up(user, digest, metadata, provider, identity, %UserToken{} = donor) do
    mfa_verified_at = if provider.satisfies_mfa, do: DateTime.utc_now()

    session(user, digest, metadata, :sso, mfa_verified_at, user_identity_id: identity.id)
    |> put_change(:personal_proved_at, donor.personal_proved_at)
    |> put_change(:personal_expires_at, donor.personal_expires_at)
    |> put_change(:mfa_enrollment_verified_at, donor.mfa_enrollment_verified_at)
    |> put_change(:local_mfa_expires_at, donor.local_mfa_expires_at)
  end

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

  @doc "Split-code proof of a new address, bound to the MFA enrollment that authorized it."
  def new_email(%Users.User{} = user, digest, new_email, attempts) do
    change(%UserToken{},
      token: digest,
      context: "email_change_new",
      sent_to: new_email,
      user_id: user.id,
      remaining_attempts: attempts,
      metadata: new_email_metadata(user)
    )
  end

  @doc "Metadata a pending new-address proof must still match: the authorizing MFA enrollment."
  def new_email_metadata(%Users.User{mfa_enabled_at: nil}), do: %{"mfa_enabled_at" => nil}

  def new_email_metadata(%Users.User{mfa_enabled_at: %DateTime{} = enabled_at}),
    do: %{"mfa_enabled_at" => DateTime.to_iso8601(enabled_at)}

  @doc "Current-inbox proof for one explicit OIDC identity action."
  def oidc_identity_step_up(%Users.User{} = user, digest, provider_id, purpose, attempts)
      when is_binary(digest) and is_binary(provider_id) and
             purpose in [:link, :verify_provider, :unlink] and is_integer(attempts) do
    change(%UserToken{},
      token: digest,
      context: "oidc_identity_step_up",
      sent_to: user.email,
      user_id: user.id,
      remaining_attempts: attempts,
      metadata: %{
        "provider_id" => provider_id,
        "purpose" => Atom.to_string(purpose),
        "user_updated_at" => DateTime.to_iso8601(user.updated_at)
      }
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

  # The sessions list renders two string-keyed fields; a blank stays out.
  defp normalize_metadata(metadata) do
    %{
      "ip_address" => to_string_or_nil(metadata[:ip_address]),
      "user_agent" => to_string_or_nil(metadata[:user_agent])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp to_string_or_nil(nil), do: nil

  defp to_string_or_nil(value) when is_binary(value),
    do: String.slice(value, 0, @metadata_value_limit)

  defp to_string_or_nil(value), do: value |> to_string() |> to_string_or_nil()
end
