defmodule Emisar.SSO.GroupRunnerAccessMapping.Changeset do
  use Emisar, :changeset
  alias Emisar.SSO.GroupRunnerAccessMapping

  # The persisted `runner_scope_*` arrays are deliberately NOT cast — they are
  # derived from the raw `scope` selection, so a submitted array can never
  # widen the grant.
  @fields ~w[external_group_id external_group_display runner_access_mode scope]a
  @update_fields List.delete(@fields, :external_group_id)
  @max_string_length 255
  @no_runner_facts %{groups: [], runners: []}

  def create(account_id, provider_id, attrs, allowlist \\ @no_runner_facts) do
    %GroupRunnerAccessMapping{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:provider_id, provider_id)
    |> validate_required([:account_id, :provider_id, :external_group_id])
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
    |> validate_length(:external_group_id, max: @max_string_length)
    |> validate_length(:external_group_display, max: @max_string_length)
    |> Emisar.Accounts.RunnerAccess.validate_selection(:runner, :scope, allowlist)
    |> validate_exclusion(:runner_access_mode, [:none], message: "must grant runner access")
    |> unique_constraint([:provider_id, :external_group_id],
      name: :sso_directory_group_runner_access_mappings_provider_group_index
    )
    |> foreign_key_constraint(:provider_id,
      name: :sso_group_runner_access_provider_account_fkey
    )
  end
end
