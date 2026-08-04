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
    # nil = keep forever · N = the daily Catalog sweep (and the packs page
    # "Clean up now") deletes pack versions no runner has advertised for N days.
    field :pack_unseen_retention_days, :integer
    # nil = keep forever · N = the hourly Runners sweep (and the runners page
    # "Clean up now") soft-deletes runners cleanly offline for N hours.
    field :runner_inactive_retention_hours, :integer
  end

  @fields ~w[require_mfa require_sso monthly_report_opt_out pack_unseen_retention_days]a
  # `Emisar.Approvals` owns the standing-grant cap end to end — the permission,
  # the meaning of 0 (the account-wide kill switch), and the revocation sweep
  # that has to follow it — so the generic settings path casts it only to refuse
  # it. A caller that could set it here would arm or disarm that kill switch
  # past every one of those gates, leaving live grants behind it.
  @approvals_owned_field :max_grant_lifetime_seconds
  # `Emisar.Runners` owns the inactivity window end to end — the permission, the
  # unrestricted-runner-access requirement, and the period's validation — so the
  # generic settings path casts it only to refuse it. A caller that could set it
  # here would arm a fleet-wide destructive sweep through the plain account
  # update, past every one of those gates.
  @runners_owned_field :runner_inactive_retention_hours

  def changeset(%__MODULE__{} = settings, attrs) do
    settings
    |> cast(attrs, [@approvals_owned_field, @runners_owned_field | @fields])
    |> reject_owned_change(@approvals_owned_field, "is set through the approval settings")
    |> reject_owned_change(@runners_owned_field, "is set through the runner settings")
    |> validate_bounds()
  end

  @doc """
  Internal — the standing-grant cap `Emisar.Approvals` has already authorized
  and validated; the one path allowed to write it. `nil` removes the cap, `0`
  disables standing grants.
  """
  def max_grant_lifetime_changeset(%__MODULE__{} = settings, attrs) do
    settings
    |> cast(attrs, [@approvals_owned_field])
    |> validate_bounds()
  end

  @doc """
  Internal — the inactivity window `Emisar.Runners` has already authorized and
  validated; the one path allowed to write it. `nil` turns the sweep off.
  """
  def runner_inactive_retention_changeset(%__MODULE__{} = settings, attrs) do
    settings
    |> cast(attrs, [@runners_owned_field])
    |> validate_bounds()
  end

  defp reject_owned_change(changeset, field, message) do
    case fetch_change(changeset, field) do
      {:ok, _value} -> add_error(changeset, field, message)
      :error -> changeset
    end
  end

  defp validate_bounds(changeset) do
    changeset
    |> validate_number(:max_grant_lifetime_seconds, greater_than_or_equal_to: 0)
    |> validate_number(:pack_unseen_retention_days, greater_than: 0)
    |> validate_number(@runners_owned_field, greater_than: 0)
  end
end
