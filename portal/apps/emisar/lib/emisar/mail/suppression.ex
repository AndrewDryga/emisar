defmodule Emisar.Mail.Suppression do
  use Emisar, :schema

  schema "email_suppressions" do
    field :email, :string
    field :reason, Ecto.Enum, values: [:hard_bounce, :spam_complaint, :manual]
    field :detail, :string

    timestamps()
  end
end
