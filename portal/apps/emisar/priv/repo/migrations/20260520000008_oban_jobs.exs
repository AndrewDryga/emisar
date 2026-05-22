defmodule Emisar.Repo.Migrations.ObanJobs do
  use Ecto.Migration

  def up do
    Oban.Migrations.up(version: 14)
  end

  def down do
    Oban.Migrations.down(version: 1)
  end
end
