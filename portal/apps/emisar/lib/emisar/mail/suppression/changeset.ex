defmodule Emisar.Mail.Suppression.Changeset do
  use Emisar, :changeset
  alias Emisar.Mail.Suppression

  @fields ~w[email reason detail]a

  @doc "Builds a suppression row. Email is trimmed; citext + unique index dedupe."
  def suppress(attrs) do
    %Suppression{}
    |> cast(attrs, @fields)
    |> update_change(:email, &String.trim/1)
    |> validate_required([:email, :reason])
    |> validate_length(:email, max: 320)
    |> validate_length(:detail, max: 1000)
    |> unique_constraint(:email)
  end
end
