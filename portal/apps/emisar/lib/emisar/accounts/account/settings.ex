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
    # nil = no cap · N = grants may live at most N seconds · 0 = standing
    # grants DISABLED (mint + match both refuse; every approval is single-use)
    field :max_grant_lifetime_seconds, :integer
    # Opt-out for the monthly account-health report email. Default false =
    # receiving; the email's one-click List-Unsubscribe link flips it true.
    field :monthly_report_opt_out, :boolean, default: false
  end

  @fields ~w[require_mfa require_sso max_grant_lifetime_seconds monthly_report_opt_out]a

  def changeset(%__MODULE__{} = settings, attrs) do
    settings
    |> cast(attrs, @fields)
    |> validate_number(:max_grant_lifetime_seconds, greater_than_or_equal_to: 0)
  end
end
