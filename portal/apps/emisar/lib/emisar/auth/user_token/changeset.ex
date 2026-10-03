defmodule Emisar.Auth.UserToken.Changeset do
  use Emisar, :changeset
  alias Emisar.{Accounts, SSO}
  alias Emisar.Auth.UserToken

  @metadata_value_limit 255

  @doc """
  Email-code session row for one Member. Persists the digest (never the raw
  bearer), the digest of the minting browser's id, and request metadata for the
  Profile sessions list. `mfa_verified_at` is when this sign-in verified the
  Member's TOTP, or nil; a verified factor also binds the session to the
  Member's current enrollment.
  """
  def session(
        %Accounts.Membership{} = membership,
        digest,
        browser_digest,
        metadata,
        mfa_verified_at
      )
      when is_binary(digest) and is_binary(browser_digest) and
             (is_nil(mfa_verified_at) or is_struct(mfa_verified_at, DateTime)) do
    mfa_enrollment_verified_at = if mfa_verified_at, do: membership.mfa_enabled_at

    local_mfa_expires_at =
      if mfa_enrollment_verified_at, do: UserToken.Query.session_expires_at(DateTime.utc_now())

    %UserToken{}
    |> change(
      token: digest,
      context: "session",
      account_id: membership.account_id,
      membership_id: membership.id,
      browser_digest: browser_digest,
      metadata: normalize_metadata(metadata),
      auth_method: :magic_link,
      mfa_verified_at: mfa_verified_at,
      mfa_enrollment_verified_at: mfa_enrollment_verified_at,
      local_mfa_expires_at: local_mfa_expires_at
    )
    |> owner_constraints()
  end

  @doc """
  SSO session row for one Member. It freezes the exact route it proved — the
  identity, the provider's issuer and the identity's subject — so the session
  ends when any of them changes. `mfa_verified_at` records the IdP's assurance
  only when the locked provider satisfies MFA.
  """
  def sso_session(
        %Accounts.Membership{} = membership,
        digest,
        browser_digest,
        metadata,
        %SSO.UserIdentity{} = identity,
        %SSO.IdentityProvider{} = provider
      )
      when is_binary(digest) and is_binary(browser_digest) do
    %UserToken{}
    |> change(
      token: digest,
      context: "session",
      account_id: membership.account_id,
      membership_id: membership.id,
      browser_digest: browser_digest,
      metadata: normalize_metadata(metadata),
      auth_method: :sso,
      mfa_verified_at: if(provider.satisfies_mfa, do: DateTime.utc_now()),
      user_identity_id: identity.id,
      sso_issuer: provider.issuer,
      sso_provider_identifier: identity.provider_identifier
    )
    |> owner_constraints()
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

  @doc """
  Split-code email sign-in row for one Member. `digest` is
  `Crypto.hash(nonce <> secret)` — neither half is stored, so a DB breach plus
  an intercepted email still can't sign in. `attempts` is the online-guess
  budget for the 6-character secret. A code that accepts an invitation carries
  that invitation's token digest and the name the invitee typed; completing it
  accepts exactly that invitation for this Member.
  """
  def magic_link(%Accounts.Membership{} = membership, digest, attempts, invitation \\ nil)
      when is_binary(digest) and is_integer(attempts) do
    %UserToken{}
    |> change(
      token: digest,
      context: "magic_link",
      sent_to: membership.email,
      account_id: membership.account_id,
      membership_id: membership.id,
      remaining_attempts: attempts,
      metadata: magic_link_metadata(invitation)
    )
    |> owner_constraints()
  end

  defp magic_link_metadata(nil), do: %{}

  defp magic_link_metadata(%{token_digest: token_digest, display_name: display_name})
       when is_binary(token_digest) and is_binary(display_name) do
    %{"invitation_token_digest" => token_digest, "invitation_display_name" => display_name}
  end

  @doc "Promotes this exact split token into the short-lived factor final session minting consumes."
  def verified_magic_link(%UserToken{context: "magic_link"} = token, %DateTime{} = verified_at) do
    change(token,
      context: "magic_link_verified",
      metadata: Map.put(token.metadata || %{}, "verified_at", DateTime.to_iso8601(verified_at))
    )
  end

  @doc """
  Split-code sign-up row. It belongs to no Member: the workspace and its owner
  are created only when the code comes back, from the intent stored here. An
  address holds at most one pending sign-up code
  (`auth_user_tokens_sign_up_address_index`).
  """
  def sign_up(digest, sent_to, attempts, %{account_name: account_name, full_name: full_name})
      when is_binary(digest) and is_binary(sent_to) and is_integer(attempts) and
             is_binary(account_name) and (is_binary(full_name) or is_nil(full_name)) do
    %UserToken{}
    |> change(
      token: digest,
      context: "sign_up",
      sent_to: sent_to,
      remaining_attempts: attempts,
      metadata: %{"account_name" => account_name, "full_name" => full_name}
    )
    |> owner_constraints()
    |> unique_constraint(:sent_to, name: :auth_user_tokens_sign_up_address_index)
  end

  @doc "Marks this exact sign-up code verified; it stays a `sign_up` row until completion consumes it."
  def verified_sign_up(%UserToken{context: "sign_up"} = token, %DateTime{} = verified_at) do
    change(token,
      metadata: Map.put(token.metadata || %{}, "verified_at", DateTime.to_iso8601(verified_at))
    )
  end

  @doc "Current-inbox proof for verifying one SSO connection."
  def oidc_identity_step_up(%Accounts.Membership{} = membership, digest, provider_id, attempts)
      when is_binary(digest) and is_binary(provider_id) and is_integer(attempts) do
    %UserToken{}
    |> change(
      token: digest,
      context: "oidc_identity_step_up",
      sent_to: membership.email,
      account_id: membership.account_id,
      membership_id: membership.id,
      remaining_attempts: attempts,
      metadata: %{
        "provider_id" => provider_id,
        "membership_updated_at" => DateTime.to_iso8601(membership.updated_at)
      }
    )
    |> owner_constraints()
  end

  @doc "Pending current-inbox code, promoted only after its email is accepted for delivery."
  def pending_mfa_enrollment(%Accounts.Membership{} = membership, digest, attempts)
      when is_binary(digest) and is_integer(attempts) do
    %UserToken{}
    |> change(
      token: digest,
      context: "mfa_enrollment_pending",
      sent_to: membership.email,
      account_id: membership.account_id,
      membership_id: membership.id,
      remaining_attempts: attempts,
      metadata: %{"membership_updated_at" => DateTime.to_iso8601(membership.updated_at)}
    )
    |> owner_constraints()
  end

  @doc "Makes a delivered current-inbox code eligible for MFA-enrollment verification."
  def activate_mfa_enrollment(%UserToken{} = token),
    do: change(token, context: "mfa_enrollment")

  @doc "Spend one attempt on a typable emailed code."
  def decrement_attempts(%UserToken{remaining_attempts: n} = token) when is_integer(n),
    do: change(token, remaining_attempts: n - 1)

  defp owner_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:membership_id, name: :auth_user_tokens_membership_fkey)
    |> check_constraint(:membership_id, name: :auth_user_tokens_owner_check)
  end

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
