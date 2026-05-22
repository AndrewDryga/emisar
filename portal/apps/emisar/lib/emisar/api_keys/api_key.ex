defmodule Emisar.ApiKeys.ApiKey do
  @moduledoc """
  An API key for programmatic access. Authenticates MCP tool callers
  (Claude, Cursor, custom runners). `runner_filter` restricts which
  runners a key may target; empty means "all runners in this account."
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_scopes ~w(actions:read actions:execute runbooks:execute audit:read)

  schema "api_keys" do
    field :name, :string
    field :description, :string

    field :key_prefix, :string
    field :key_hash, :binary, redact: true

    field :runner_filter, {:array, :string}, default: []
    field :scopes, {:array, :string}, default: []

    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account
    belongs_to :created_by, Emisar.Accounts.User
    belongs_to :revoked_by, Emisar.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(key, attrs) do
    key
    |> cast(attrs, [:account_id, :created_by_id, :name, :description, :runner_filter, :scopes, :expires_at])
    |> validate_required([:account_id, :name, :scopes])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_subset(:scopes, @valid_scopes)
  end

  def usage_changeset(key, at \\ DateTime.utc_now()) do
    change(key, last_used_at: DateTime.truncate(at, :microsecond))
  end

  def revoke_changeset(key, by_user_id, at \\ DateTime.utc_now()) do
    change(key,
      revoked_at: DateTime.truncate(at, :microsecond),
      revoked_by_id: by_user_id
    )
  end

  def usable?(%__MODULE__{revoked_at: nil, expires_at: nil}), do: true

  def usable?(%__MODULE__{revoked_at: nil, expires_at: exp}),
    do: DateTime.compare(DateTime.utc_now(), exp) == :lt

  def usable?(_), do: false

  def valid_scopes, do: @valid_scopes
end
