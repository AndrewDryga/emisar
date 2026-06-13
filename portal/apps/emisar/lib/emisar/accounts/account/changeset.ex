defmodule Emisar.Accounts.Account.Changeset do
  use Emisar, :changeset
  alias Emisar.Accounts.Account

  @plans ~w(free team enterprise)
  @create_fields ~w[name slug plan paddle_customer_id]a
  # update/2 may also flip the security settings (require_mfa); the
  # context's field-aware permission check (Accounts.update_account/3)
  # decides who may change which field.
  @update_fields ~w[name slug plan paddle_customer_id require_mfa]a

  def create(attrs) do
    %Account{}
    |> cast(attrs, @create_fields)
    |> changeset()
  end

  def update(%Account{} = account, attrs) do
    account |> cast(attrs, @update_fields) |> changeset()
  end

  def link_paddle_customer(%Account{} = account, customer_id) when is_binary(customer_id),
    do: change(account, paddle_customer_id: customer_id)

  def plans, do: @plans

  defp changeset(changeset) do
    changeset
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:slug, ~r/^[a-z][a-z0-9-]{1,62}[a-z0-9]$/,
      message: "must be lowercase letters/numbers/hyphens, start with a letter, 3-64 chars"
    )
    # Write-side guard only — reads tolerate legacy plan names (see the
    # schema's `plan` field note); an Ecto.Enum can't express that split.
    |> validate_inclusion(:plan, @plans)
    |> unique_constraint(:slug)
  end
end
