defmodule Emisar.Repo.Migrations.CreateMarketingSignups do
  use Ecto.Migration

  def change do
    create table(:marketing_signups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      # Which marketing page/CTA the signup came from — so we can see what converts.
      add :source, :string

      timestamps()
    end

    create unique_index(:marketing_signups, [:email])
  end
end
