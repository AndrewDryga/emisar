defmodule Emisar.Runners.Runner.Changeset do
  @moduledoc """
  All changesets for `%Emisar.Runners.Runner{}`. The schema itself is
  data-only — every transition (registration, manual create, advertised
  state, connected, disconnected, disabled, deleted) lives here as a
  single-purpose changeset.
  """
  use Emisar, :changeset
  alias Emisar.Runners.Runner

  # -- Bootstrap paths -------------------------------------------------

  @doc "Inserted by the runner socket on first auth-key registration."
  def register(attrs) do
    %Runner{}
    |> cast(ensure_external_id(attrs), [
      :account_id,
      :name,
      :external_id,
      :group,
      :hostname,
      :labels,
      :runner_version,
      :bootstrap_auth_key_id
    ])
    |> validate_required([:account_id, :name, :external_id, :group])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:group, min: 1, max: 80)
    |> unique_constraint([:account_id, :external_id])
    |> unique_constraint(:name,
      name: :runners_account_id_name_index,
      message: "is already used by another runner in this account"
    )
  end

  @doc """
  Manual operator-created runner from the dashboard / seeds / tests.
  Auto-generates `external_id` when the caller didn't supply one, so
  every runner row always has the stable id `apply_state` matches on
  during reconnects.
  """
  def create(%Emisar.Accounts.Account{} = account, attrs) do
    %Runner{}
    |> cast(ensure_external_id(attrs), [:name, :external_id, :group, :labels])
    |> put_change(:account_id, account.id)
    |> validate_required([:name, :external_id, :group])
    |> validate_length(:name, min: 1, max: 80)
    |> unique_constraint([:account_id, :external_id])
    |> unique_constraint(:name,
      name: :runners_account_id_name_index,
      message: "is already used by another runner in this account"
    )
  end

  # Attribute-key-agnostic default: only fills `external_id` when the
  # caller didn't pass one (string-key or atom-key). Idempotent.
  defp ensure_external_id(attrs) do
    cond do
      is_binary(Map.get(attrs, :external_id)) and Map.get(attrs, :external_id) != "" ->
        attrs

      is_binary(Map.get(attrs, "external_id")) and Map.get(attrs, "external_id") != "" ->
        attrs

      is_map(attrs) ->
        key =
          if Enum.any?(attrs, fn {k, _} -> is_atom(k) end), do: :external_id, else: "external_id"

        Map.put(attrs, key, Ecto.UUID.generate())

      true ->
        attrs
    end
  end

  # -- Lifecycle transitions ------------------------------------------

  def update(%Runner{} = runner, attrs) do
    runner
    |> cast(attrs, [:name, :group, :labels])
    |> validate_required([:name, :group])
    |> validate_length(:name, min: 1, max: 80)
  end

  @doc "Apply a runner_state advertisement (hostname, labels, version, packs)."
  def apply_state(%Runner{} = runner, attrs) do
    # external_id is set at create / register time and is the stable
    # match key for reconnects — never overwrite it from a runner_state
    # payload (the runner may serialize it as JSON null on the wire,
    # which Ecto's cast would write through as nil and trip the
    # NOT NULL constraint).
    cast(runner, attrs, [:hostname, :labels, :runner_version, :packs])
  end

  # Connect/disconnect stamp the durable "last seen" history only.
  # "Online now" is Phoenix.Presence — there's no status column to flip.
  def connected(%Runner{} = runner) do
    change(runner, last_connected_at: now(), last_disconnect_reason: nil)
  end

  def disconnected(%Runner{} = runner, reason \\ nil) do
    change(runner, last_disconnected_at: now(), last_disconnect_reason: reason)
  end

  def disable(%Runner{} = runner) do
    change(runner, disabled_at: now())
  end

  def delete(%Runner{} = runner) do
    change(runner, deleted_at: now())
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
