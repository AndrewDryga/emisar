defmodule Emisar.Repo.Migrations.AddLastReportSentAtToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      # When the monthly account-health value report was last delivered.
      # The report job derives its work set from this column (null or older
      # than the current month = due), so a repeated tick can't double-send.
      add :last_report_sent_at, :utc_datetime_usec
    end
  end
end
