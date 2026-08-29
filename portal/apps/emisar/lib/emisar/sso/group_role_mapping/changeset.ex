defmodule Emisar.SSO.GroupRoleMapping.Changeset do
  use Emisar, :changeset
  alias Emisar.SSO.GroupRoleMapping

  @create_fields ~w[directory_group_id role]a
  @update_fields ~w[role]a
  @max_string_length 255

  def form(account_id, provider_id, attrs) do
    %GroupRoleMapping{}
    |> cast(attrs, @create_fields)
    |> put_change(:account_id, account_id)
    |> put_change(:provider_id, provider_id)
    |> validate_required([:account_id, :provider_id, :directory_group_id, :role])
    |> changeset()
  end

  def create(account_id, provider_id, group, attrs) do
    %GroupRoleMapping{}
    |> cast(attrs, @create_fields)
    |> put_change(:account_id, account_id)
    |> put_change(:provider_id, provider_id)
    |> put_change(:directory_group_id, group.id)
    |> put_change(:external_group_id, group.external_group_id)
    |> put_change(:external_group_display, group.display)
    |> validate_required([:account_id, :provider_id, :directory_group_id, :role])
    |> changeset()
  end

  def update(%GroupRoleMapping{} = mapping, attrs) do
    mapping
    |> cast(attrs, @update_fields)
    |> validate_required([:role])
    |> changeset()
  end

  def delete(%GroupRoleMapping{} = mapping),
    do: change(mapping, deleted_at: DateTime.utc_now())

  defp changeset(changeset) do
    changeset
    # Directory sync can never grant owner — owner stays a deliberate human
    # assignment (decision 7). Defense in depth: `Accounts.sync_set_membership_role/3`
    # also refuses `:owner`, but rejecting it here keeps an owner mapping from
    # ever being stored in the first place.
    |> validate_length(:external_group_display, max: @max_string_length, count: :codepoints)
    |> validate_exclusion(:role, [:owner], message: "directory sync cannot grant owner")
    |> unique_constraint([:provider_id, :directory_group_id],
      name: :sso_group_role_mappings_provider_group_id_index
    )
    |> foreign_key_constraint(:directory_group_id,
      name: :sso_group_role_mapping_directory_group_fkey
    )
  end
end
