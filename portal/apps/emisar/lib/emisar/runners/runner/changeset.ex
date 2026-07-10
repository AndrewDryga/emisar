defmodule Emisar.Runners.Runner.Changeset do
  @moduledoc """
  All changesets for `%Emisar.Runners.Runner{}`. The schema itself is
  data-only — every transition (registration, advertised state, connected,
  disconnected, disabled, deleted) lives here as a
  single-purpose changeset.
  """
  use Emisar, :changeset
  alias Emisar.Runners.Runner

  # Generous caps on runner-advertised fields. A frame is already bounded to
  # ~1 MB by the socket, but a hostile authenticated runner could loop
  # state/register advertisements to grow its own account's row (and every
  # render of it). `hostname` is a DNS name (≤253 chars); `runner_version` is a
  # semver-ish string — 255 is far above either. `labels`/`packs` are free-form
  # jsonb a real runner keeps to a handful of KB, so 64 KB serialized is well
  # above any honest advertisement while bounding the gross-abuse row.
  @max_hostname_length 255
  @max_group_length 80
  @max_runner_version_length 255
  @max_json_bytes 65_536

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
      :bootstrap_enrollment_key_id
    ])
    |> validate_required([:account_id, :name, :external_id, :group])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:group, min: 1)
    |> validate_advertised_fields()
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

      true ->
        key =
          if Enum.any?(attrs, fn {k, _} -> is_atom(k) end), do: :external_id, else: "external_id"

        Map.put(attrs, key, Ecto.UUID.generate())
    end
  end

  # -- Lifecycle transitions ------------------------------------------

  @doc "Apply a runner_state advertisement (hostname, labels, version, packs)."
  def apply_state(%Runner{} = runner, attrs) do
    # external_id is set at create / register time and is the stable
    # match key for reconnects — never overwrite it from a runner_state
    # payload (the runner may serialize it as JSON null on the wire,
    # which Ecto's cast would write through as nil and trip the
    # NOT NULL constraint).
    # `group` is included so a config `runner.group` rename propagates on the
    # next reconnect; the caller only passes a non-blank value (otherwise the
    # existing group is kept), so this never wipes a group to "".
    # `enforce_signatures` is runner-advertised too — a runner can only make
    # itself stricter, so it's trusted like `group` (the host is the anchor).
    runner
    |> cast(attrs, [
      :hostname,
      :labels,
      :runner_version,
      :packs,
      :group,
      :enforce_signatures,
      :max_attestation_age_seconds
    ])
    |> validate_advertised_fields()
  end

  # Bound the runner-controlled fields so a hostile authenticated runner can't
  # grow its account's row by advertising oversized values. Each check only
  # fires when its field is in this changeset, so the bootstrap paths (which
  # cast a subset) reuse the same helper.
  defp validate_advertised_fields(changeset) do
    changeset
    |> validate_length(:group, max: @max_group_length)
    |> validate_length(:hostname, max: @max_hostname_length)
    |> validate_length(:runner_version, max: @max_runner_version_length)
    |> validate_json_size(:labels, @max_json_bytes)
    |> validate_json_size(:packs, @max_json_bytes)
    |> validate_number(:max_attestation_age_seconds, greater_than: 0)
  end

  # Connect/disconnect stamp the durable "last seen" history only.
  # "Online now" is Phoenix.Presence — there's no status column to flip.
  def connected(%Runner{} = runner) do
    change(runner, last_connected_at: DateTime.utc_now(), last_disconnect_reason: nil)
  end

  def disconnected(%Runner{} = runner, reason \\ nil) do
    change(runner, last_disconnected_at: DateTime.utc_now(), last_disconnect_reason: reason)
  end

  def disable(%Runner{} = runner) do
    change(runner, disabled_at: DateTime.utc_now())
  end

  def enable(%Runner{} = runner) do
    change(runner, disabled_at: nil)
  end

  def delete(%Runner{} = runner) do
    change(runner, deleted_at: DateTime.utc_now())
  end
end
