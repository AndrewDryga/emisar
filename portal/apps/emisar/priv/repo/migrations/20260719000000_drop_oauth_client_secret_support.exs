defmodule Emisar.Repo.Migrations.DropOauthClientSecretSupport do
  use Ecto.Migration

  def change do
    alter table(:oauth_clients) do
      remove :token_endpoint_auth_method, :string, null: false, default: "none"
      remove :client_secret_hash, :binary
    end
  end
end
