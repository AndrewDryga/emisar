defmodule Emisar.Accounts.User.Changeset do
  use Emisar, :changeset
  alias Emisar.Accounts.User

  def registration(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :full_name, :password])
    |> validate_email_field()
    |> validate_optional_password(opts)
  end

  def email(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_email_field()
    |> case do
      %{changes: %{email: _}} = cs -> cs
      %{} = cs -> add_error(cs, :email, "did not change")
    end
  end

  def password(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password_field(opts)
  end

  def profile(user, attrs), do: cast(user, attrs, [:full_name])

  def confirm(%User{} = user),
    do: change(user, confirmed_at: now())

  def sign_in(%User{} = user),
    do: change(user, last_sign_in_at: now())

  def mfa(%User{} = user, secret, enabled_at),
    do: change(user, mfa_secret: secret, mfa_enabled_at: enabled_at)

  def delete(%User{} = user), do: change(user, deleted_at: now())

  defp validate_email_field(cs) do
    cs
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, Emisar.Repo)
    |> unique_constraint(:email)
  end

  defp validate_optional_password(cs, opts) do
    if get_change(cs, :password),
      do: validate_password_field(cs, opts),
      else: cs
  end

  defp validate_password_field(cs, opts) do
    cs
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 128)
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(cs, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(cs, :password)

    if hash_password? && password && cs.valid? do
      cs
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      cs
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
