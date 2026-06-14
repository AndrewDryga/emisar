defmodule Emisar.Repo.Migrations.EmailSuppressions do
  use Ecto.Migration

  # Addresses that hard-bounced or filed a spam complaint, fed from the
  # Postmark bounce/complaint webhook. The transactional mailer checks this
  # list before every send and skips suppressed addresses, so we don't keep
  # mailing a dead address and burning sender reputation. Email is the natural
  # key (citext → case-insensitive match, unique).
  def change do
    create table(:email_suppressions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :reason, :string, null: false
      add :detail, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:email_suppressions, [:email])
  end
end
