defmodule Emisar.Accounts.SignUpInput do
  @moduledoc """
  One sign-up submission — the owner's address and name, and the name of the
  workspace to create. Never persisted: `Accounts` casts the raw form params
  through it, so the browser form and the sign-up code share ONE definition of a
  valid sign-up. The intent rides the sign-up code server-side until the
  address is proved; nothing is created before that.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :email, :string
    field :full_name, :string
    field :account_name, :string
  end

  @fields ~w[email full_name account_name]a

  @doc """
  Casts one sign-up submission. A valid changeset carries the trimmed address,
  the trimmed workspace name, and an optional name of at most 255 characters,
  the limit of the owner's display name.
  """
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> update_change(:email, &String.trim/1)
    |> update_change(:account_name, &String.trim/1)
    |> update_change(:full_name, &blank_to_nil/1)
    |> validate_required([:email, :account_name])
    |> Emisar.EmailAddress.validate(:email)
    |> validate_length(:full_name, max: 255, count: :codepoints)
  end

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
