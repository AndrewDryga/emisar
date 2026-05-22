defmodule Emisar.Auth do
  @moduledoc """
  Authentication: sign in/up flows, session tokens, magic links,
  password resets, email confirmation, MFA scaffold.

  All token types share `user_tokens` storage; `context` disambiguates
  semantics + validity window.
  """

  alias Emisar.Accounts
  alias Emisar.Accounts.User
  alias Emisar.Auth.UserToken
  alias Emisar.Repo

  # -- Password sign in -------------------------------------------------

  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Accounts.get_user_by_email(email)

    if User.valid_password?(user, password) do
      user
    else
      nil
    end
  end

  # -- Session tokens ---------------------------------------------------

  @doc "Returns {raw_token, persisted_struct}."
  def create_session_token(%User{} = user) do
    {token, struct} = UserToken.build_session_token(user)
    Repo.insert!(struct)
    token
  end

  def get_user_by_session_token(token) when is_binary(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  def delete_session_token(token) when is_binary(token) do
    Repo.delete_all(UserToken.delete_session_token_query(token))
    :ok
  end

  def delete_all_session_tokens(%User{} = user) do
    Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["session"]))
    :ok
  end

  # -- Magic link -------------------------------------------------------

  @doc "Issues a magic-link token. Returns the raw token to email."
  def issue_magic_link_token(%User{} = user) do
    {raw, struct} = UserToken.build_hashed_token(user, "magic_link", user.email)
    Repo.insert!(struct)
    raw
  end

  @doc "Consumes a magic-link token, returning the user or {:error, reason}."
  def consume_magic_link_token(raw) when is_binary(raw) do
    case UserToken.verify_hashed_token_query(raw, "magic_link") do
      {:ok, query} ->
        case Repo.one(query) do
          nil -> {:error, :invalid_or_expired}
          {user, token} ->
            Repo.delete!(token)
            {:ok, user}
        end

      :error ->
        {:error, :invalid_or_expired}
    end
  end

  # -- Password reset ---------------------------------------------------

  def issue_password_reset_token(%User{} = user) do
    {raw, struct} = UserToken.build_hashed_token(user, "reset_password", user.email)
    Repo.insert!(struct)
    raw
  end

  def reset_user_password(raw, password) when is_binary(raw) do
    case UserToken.verify_hashed_token_query(raw, "reset_password") do
      {:ok, query} ->
        case Repo.one(query) do
          nil ->
            {:error, :invalid_or_expired}

          {user, token} ->
            Repo.transaction(fn ->
              {:ok, updated} =
                user
                |> User.password_changeset(%{password: password})
                |> Repo.update()

              Repo.delete!(token)
              # Invalidate all sessions so the reset acts like a logout.
              Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["session"]))
              updated
            end)
        end

      :error ->
        {:error, :invalid_or_expired}
    end
  end

  # -- Email confirmation ----------------------------------------------

  def issue_confirmation_token(%User{} = user) do
    {raw, struct} = UserToken.build_hashed_token(user, "confirm", user.email)
    Repo.insert!(struct)
    raw
  end

  def confirm_user_by_token(raw) when is_binary(raw) do
    case UserToken.verify_hashed_token_query(raw, "confirm") do
      {:ok, query} ->
        case Repo.one(query) do
          nil ->
            {:error, :invalid_or_expired}

          {user, token} ->
            Repo.transaction(fn ->
              {:ok, confirmed} = Accounts.confirm_user(user)
              Repo.delete!(token)
              confirmed
            end)
        end

      :error ->
        {:error, :invalid_or_expired}
    end
  end

  # -- MFA scaffold -----------------------------------------------------

  @doc """
  Generates a fresh TOTP secret for the user. Caller is responsible
  for displaying the QR code; nothing is persisted until
  `enable_mfa/2` confirms the user has the secret.
  """
  def generate_mfa_secret, do: NimbleTOTP.secret()

  def enable_mfa(%User{} = user, secret, otp) when is_binary(secret) and is_binary(otp) do
    if NimbleTOTP.valid?(secret, otp) do
      user
      |> User.mfa_changeset(secret, DateTime.utc_now() |> DateTime.truncate(:microsecond))
      |> Repo.update()
    else
      {:error, :invalid_otp}
    end
  end

  def disable_mfa(%User{} = user) do
    user
    |> User.mfa_changeset(nil, nil)
    |> Repo.update()
  end

  def mfa_required?(%User{mfa_enabled_at: nil}), do: false
  def mfa_required?(%User{}), do: true

  def verify_mfa(%User{mfa_secret: secret}, otp) when is_binary(secret) and is_binary(otp),
    do: NimbleTOTP.valid?(secret, otp)
end
