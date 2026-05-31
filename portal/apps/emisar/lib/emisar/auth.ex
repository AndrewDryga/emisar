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

  @doc """
  Looks up a user by email and verifies the password. Returns
  `{:ok, user}` on a match or `{:error, :not_found}` for unknown email
  / wrong password. Pre-auth boundary — no Subject.
  """
  def fetch_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user =
      case Accounts.fetch_user_by_email(email) do
        {:ok, u} -> u
        {:error, :not_found} -> nil
      end

    # `valid_password?(nil, _)` falls through to Bcrypt.no_user_verify/0
    # so timing is constant whether or not the email matched a row.
    if User.valid_password?(user, password) do
      {:ok, user}
    else
      {:error, :not_found}
    end
  end

  # -- Session tokens ---------------------------------------------------

  @doc """
  Mint a session token and persist it. Returns the raw token for the
  cookie. `metadata` (optional) carries `ip_address` + `user_agent`
  captured from the inbound request so the Profile page can show
  per-session device info; missing keys are tolerated.
  """
  def create_session_token!(%User{} = user, metadata \\ %{}) do
    {token, struct} = UserToken.build_session_token(user, metadata)
    Repo.insert!(struct)
    token
  end

  @doc """
  Looks up the user behind a session token. Returns `{:ok, user}` on
  a hit or `{:error, :not_found}` for expired / unknown / non-binary
  tokens. Pre-auth boundary — no Subject.
  """
  def fetch_user_by_session_token(token) when is_binary(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %User{} = user -> {:ok, user}
    end
  end

  def delete_session_token(token) when is_binary(token) do
    Repo.delete_all(UserToken.delete_session_token_query(token))
    :ok
  end

  def delete_all_session_tokens(%User{} = user) do
    UserToken.Query.by_user_id(user.id)
    |> UserToken.Query.by_contexts(["session"])
    |> Repo.delete_all()

    :ok
  end

  @doc """
  All active sessions for a user, newest first. The raw token is never
  surfaced — only the row id (for revocation) and inserted_at (display).
  Returns `{:ok, [token], %Paginator.Metadata{}}` per the context-
  function convention.
  """
  def list_sessions_for_user(%User{} = user, opts \\ []) do
    UserToken.Query.by_user_id(user.id)
    |> UserToken.Query.by_context("session")
    |> Repo.list(UserToken.Query, opts)
  end

  @doc """
  Revoke one specific session by id, scoped to the owning user so a
  malicious id from one user can't kill another's session.
  Returns :ok | {:error, :not_found}.
  """
  def revoke_session(%User{} = user, token_id) do
    if Repo.valid_uuid?(token_id) do
      case Repo.delete_all(UserToken.session_by_id_for_user_query(user, token_id)) do
        {1, _} -> :ok
        {0, _} -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Revoke every session except the one carrying `keep_token` (the
  caller's current cookie). Used by Profile's "sign out everywhere
  else". Pass `nil` to revoke every session including the current one.
  """
  def revoke_other_sessions!(%User{} = user, keep_token) when is_binary(keep_token) do
    keep_digest = :crypto.hash(:sha256, keep_token)
    {n, _} = Repo.delete_all(UserToken.other_sessions_for_user_query(user, keep_digest))
    n
  end

  def revoke_other_sessions!(%User{} = user, nil) do
    {n, _} =
      UserToken.Query.by_user_id(user.id)
      |> UserToken.Query.by_contexts(["session"])
      |> Repo.delete_all()

    n
  end

  # -- Magic link -------------------------------------------------------

  @doc "Issues a magic-link token. Returns the raw token to email."
  def issue_magic_link_token!(%User{} = user) do
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

  def issue_password_reset_token!(%User{} = user) do
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
                |> User.Changeset.password(%{password: password})
                |> Repo.update()

              Repo.delete!(token)
              # Invalidate all sessions so the reset acts like a logout.
              UserToken.Query.by_user_id(user.id)
              |> UserToken.Query.by_contexts(["session"])
              |> Repo.delete_all()

              updated
            end)
        end

      :error ->
        {:error, :invalid_or_expired}
    end
  end

  # -- Email confirmation ----------------------------------------------

  def issue_confirmation_token!(%User{} = user) do
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
      |> User.Changeset.mfa(secret, DateTime.utc_now() |> DateTime.truncate(:microsecond))
      |> Repo.update()
    else
      {:error, :invalid_otp}
    end
  end

  def disable_mfa(%User{} = user) do
    user
    |> User.Changeset.mfa(nil, nil)
    |> Repo.update()
  end

  def mfa_required?(%User{mfa_enabled_at: nil}), do: false
  def mfa_required?(%User{}), do: true

  def verify_mfa(%User{mfa_secret: secret}, otp) when is_binary(secret) and is_binary(otp),
    do: NimbleTOTP.valid?(secret, otp)
end
