defmodule Emisar.SSO.GroupRunnerAccessMapping.Changeset do
  use Emisar, :changeset
  alias Emisar.Accounts
  alias Emisar.SSO.GroupRunnerAccessMapping

  # The persisted `runner_scope_*` / `pack_scope_*` arrays are deliberately NOT
  # cast — they are derived from the raw `scope` / `pack_scope` selections, so a
  # submitted array can never widen the grant.
  @fields ~w[directory_group_id runner_access_mode scope pack_access_mode pack_scope]a
  @update_fields List.delete(@fields, :directory_group_id)
  @max_string_length 255
  @no_runner_facts %{groups: [], runners: [], packs: []}

  def form(account_id, provider_id, attrs, allowlist \\ @no_runner_facts) do
    {attrs, no_packs?} = normalize_pack_choice(attrs)

    %GroupRunnerAccessMapping{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:provider_id, provider_id)
    |> validate_required([:account_id, :provider_id, :directory_group_id])
    |> changeset(allowlist, no_packs?)
  end

  def create(account_id, provider_id, group, attrs, allowlist \\ @no_runner_facts) do
    {attrs, no_packs?} = normalize_pack_choice(attrs)

    %GroupRunnerAccessMapping{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:provider_id, provider_id)
    |> put_change(:directory_group_id, group.id)
    |> put_change(:external_group_id, group.external_group_id)
    |> put_change(:external_group_display, group.display)
    |> validate_required([:account_id, :provider_id, :directory_group_id])
    |> changeset(allowlist, no_packs?)
  end

  def update(%GroupRunnerAccessMapping{} = mapping, attrs, allowlist \\ @no_runner_facts) do
    {attrs, no_packs?} = normalize_pack_choice(attrs, mapping)

    mapping
    |> cast(attrs, @update_fields)
    |> changeset(allowlist, no_packs?)
  end

  def delete(%GroupRunnerAccessMapping{} = mapping),
    do: change(mapping, deleted_at: DateTime.utc_now())

  defp changeset(changeset, allowlist, no_packs?) do
    changeset
    |> validate_length(:external_group_display, max: @max_string_length, count: :codepoints)
    |> validate_dimensions(allowlist, no_packs?)
    |> unique_constraint([:provider_id, :directory_group_id],
      name: :sso_group_access_mappings_provider_group_id_index,
      error_key: :directory_group_id,
      message: "This group already has an access mapping."
    )
    |> foreign_key_constraint(:provider_id,
      name: :sso_group_runner_access_provider_account_fkey
    )
    |> foreign_key_constraint(:directory_group_id,
      name: :sso_group_runner_access_mapping_directory_group_fkey
    )
  end

  defp normalize_pack_choice(attrs, stored \\ nil) do
    mode = Map.get(attrs, "pack_access_mode", Map.get(attrs, :pack_access_mode))

    no_packs? =
      mode in [:none, "none"] or
        (is_nil(mode) and not is_nil(stored) and stored.pack_access_mode == :restricted and
           stored.pack_scope_pack_ids == [] and
           Map.get(attrs, "pack_scope", Map.get(attrs, :pack_scope, [])) in [nil, []])

    attrs =
      if mode in [:none, "none"] do
        if Map.has_key?(attrs, "pack_access_mode"),
          do: Map.merge(attrs, %{"pack_access_mode" => "restricted", "pack_scope" => []}),
          else: Map.merge(attrs, %{pack_access_mode: :restricted, pack_scope: []})
      else
        attrs
      end

    {attrs, no_packs?}
  end

  defp validate_dimensions(changeset, allowlist, no_packs?) do
    runners =
      Accounts.RunnerAccess.from_selection(
        get_field(changeset, :runner_access_mode),
        List.wrap(get_field(changeset, :scope)),
        allowlist
      )

    packs =
      if no_packs?,
        do: Accounts.RunnerAccess.new(:all, [], [], :restricted, []),
        else:
          Accounts.RunnerAccess.from_selection(
            :all,
            [],
            allowlist,
            get_field(changeset, :pack_access_mode),
            List.wrap(get_field(changeset, :pack_scope))
          )

    changeset =
      case runners do
        {:ok, access} ->
          changeset
          |> put_change(:runner_scope_groups, access.groups)
          |> put_change(:runner_scope_runner_ids, access.runner_ids)
          |> put_change(
            :scope,
            Accounts.RunnerAccess.selection_values(access.groups, access.runner_ids)
          )

        {:error, _} ->
          add_error(changeset, :runner_access_mode, "is invalid")
      end

    case packs do
      {:ok, access} ->
        changeset
        |> put_change(:pack_access_mode, access.pack_mode)
        |> put_change(:pack_scope_pack_ids, access.pack_ids)
        |> put_change(:pack_scope, Accounts.RunnerAccess.pack_selection_values(access.pack_ids))

      {:error, _} ->
        add_error(changeset, :pack_access_mode, "is invalid")
    end
  end
end
