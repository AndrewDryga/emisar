defmodule Emisar.Accounts.Account.Settings do
  @moduledoc """
  Account-level operator settings, embedded as the accounts `settings` jsonb
  column so the schema doesn't grow a column per toggle. **Add a new account
  setting here, not as a top-level `accounts` field** — one column, one read
  path (`Accounts.fetch_account_settings/1`), and the value object validates
  its own fields.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :require_mfa, :boolean, default: false
    field :require_sso, :boolean, default: false
    field :max_grant_lifetime_seconds, :integer
  end

  @fields ~w[require_mfa require_sso max_grant_lifetime_seconds]a

  def changeset(%__MODULE__{} = settings, attrs) do
    settings
    |> cast(attrs, @fields)
    |> validate_number(:max_grant_lifetime_seconds, greater_than: 0)
  end
end
