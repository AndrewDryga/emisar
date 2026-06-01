defmodule Emisar.Accounts.Account.Changeset do
  use Emisar, :changeset
  alias Emisar.Accounts.Account

  @plans ~w(free team enterprise)
  @fields ~w[name slug plan paddle_customer_id]a

  def create(attrs) do
    %Account{}
    |> cast(attrs, @fields)
    |> changeset()
  end

  def update(%Account{} = account, attrs) do
    account |> cast(attrs, @fields) |> changeset()
  end

  # Targeted update for security settings — owner-only, gated at the
  # context layer. Kept separate from `update/2` so the broad field
  # whitelist there can't accidentally let an admin flip require_mfa
  # by smuggling the param in.
  def update_security(%Account{} = account, attrs) do
    account |> cast(attrs, [:require_mfa])
  end

  def delete(%Account{} = account), do: change(account, deleted_at: now())

  def plans, do: @plans

  defp changeset(cs) do
    cs
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:slug, ~r/^[a-z][a-z0-9-]{1,62}[a-z0-9]$/,
      message: "must be lowercase letters/numbers/hyphens, start with a letter, 3-64 chars"
    )
    |> validate_inclusion(:plan, @plans)
    |> unique_constraint(:slug)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
