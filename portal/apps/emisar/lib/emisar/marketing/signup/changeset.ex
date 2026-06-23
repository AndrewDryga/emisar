defmodule Emisar.Marketing.Signup.Changeset do
  use Emisar, :changeset

  alias Emisar.Marketing.Signup

  @fields ~w[email source]a

  def create(attrs) do
    %Signup{}
    |> cast(attrs, @fields)
    |> update_change(:email, &String.trim/1)
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 254)
    |> validate_length(:source, max: 100)
    |> unique_constraint(:email)
  end
end
