defmodule Emisar.Accounts.Account.Changeset do
  use Emisar, :changeset
  alias Emisar.Accounts.Account

  @fields ~w[name slug paddle_customer_id]a

  def create(attrs) do
    %Account{}
    |> cast(attrs, @fields)
    |> cast_embed(:settings, with: &Account.Settings.changeset/2)
    |> put_default_settings()
    |> changeset()
  end

  # update/2 may also change the embedded settings via a nested
  # `%{settings: %{…}}`; the context's field-aware permission check
  # (`Accounts.update_account/3`) decides who may touch them. Plan is NOT
  # settable — it's derived from the subscription (`Billing.account_plan/1`).
  def update(%Account{} = account, attrs) do
    account
    |> cast(attrs, @fields)
    |> cast_embed(:settings, with: &Account.Settings.changeset/2)
    |> changeset()
  end

  def link_paddle_customer(%Account{} = account, customer_id) when is_binary(customer_id),
    do: change(account, paddle_customer_id: customer_id)

  # Settings is non-nil by construction: a brand-new account whose attrs carry
  # no settings still gets the embedded defaults, so `account.settings.<field>`
  # is always safe to read across the app.
  defp put_default_settings(changeset) do
    if get_change(changeset, :settings),
      do: changeset,
      else: put_embed(changeset, :settings, %Account.Settings{})
  end

  defp changeset(changeset) do
    changeset
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:slug, ~r/^[a-z][a-z0-9-]{1,62}[a-z0-9]$/,
      message: "must be lowercase letters/numbers/hyphens, start with a letter, 3-64 chars"
    )
    |> unique_constraint(:slug)
  end
end
