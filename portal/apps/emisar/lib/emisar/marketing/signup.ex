defmodule Emisar.Marketing.Signup do
  @moduledoc "An early-access / product-update email captured from the marketing site."
  use Emisar, :schema

  schema "marketing_signups" do
    field :email, :string
    field :source, :string

    timestamps()
  end
end
