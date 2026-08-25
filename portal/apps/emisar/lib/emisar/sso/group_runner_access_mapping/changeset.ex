defmodule Emisar.SSO.GroupRunnerAccessMapping.Changeset do
  use Emisar, :changeset
  alias Emisar.SSO.GroupRunnerAccessMapping

  # The persisted `runner_scope_*` / `pack_scope_*` arrays are deliberately NOT
  # cast — they are derived from the raw `scope` / `pack_scope` selections, so a
  # submitted array can never widen the grant.
  @fields ~w[directory_group_id runner_access_mode scope pack_access_mode pack_scope]a
  @update_fields List.delete(@fields, :directory_group_id)
  @max_string_length 255
  @no_runner_facts %{groups: [], runners: [], packs: []}

  def form(account_id, provider_id, attrs, allowlist \\ @no_runner_facts) do
    %GroupRunnerAccessMapping{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:provider_id, provider_id)
    |> validate_required([:account_id, :provider_id, :directory_group_id])
    |> changeset(allowlist)
  end

  def create(account_id, provider_id, group, attrs, allowlist \\ @no_runner_facts) do
    %GroupRunnerAccessMapping{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:provider_id, provider_id)
    |> put_change(:directory_group_id, group.id)
    |> put_change(:external_group_id, group.external_group_id)
    |> put_change(:external_group_display, group.display)
    |> validate_required([:account_id, :provider_id, :directory_group_id])
    |> changeset(allowlist)
  end

  def update(%GroupRunnerAccessMapping{} = mapping, attrs, allowlist \\ @no_runner_facts) do
    mapping
    |> cast(attrs, @update_fields)
    |> changeset(allowlist)
  end

  def delete(%GroupRunnerAccessMapping{} = mapping),
    do: change(mapping, deleted_at: DateTime.utc_now())

  defp changeset(changeset, allowlist) do
    changeset
    |> validate_length(:external_group_display, max: @max_string_length)
    |> Emisar.Accounts.RunnerAccess.validate_selection(:runner, :scope, :pack_scope, allowlist)
    |> validate_exclusion(:runner_access_mode, [:none], message: "must grant runner access")
    |> unique_constraint([:provider_id, :directory_group_id],
      name: :sso_group_access_mappings_provider_group_id_index
    )
    |> foreign_key_constraint(:provider_id,
      name: :sso_group_runner_access_provider_account_fkey
    )
    |> foreign_key_constraint(:directory_group_id,
      name: :sso_group_runner_access_mapping_directory_group_fkey
    )
  end
end
