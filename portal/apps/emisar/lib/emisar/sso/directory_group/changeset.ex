defmodule Emisar.SSO.DirectoryGroup.Changeset do
  use Emisar, :changeset
  alias Emisar.SSO.DirectoryGroup

  @max_length 255

  def create(account_id, provider_id, external_group_id, display) do
    %DirectoryGroup{}
    |> change(
      account_id: account_id,
      provider_id: provider_id,
      external_group_id: external_group_id,
      display: display
    )
    |> validate_required([:account_id, :provider_id])
    |> require_external_id_or_display()
    |> validate_length(:external_group_id, max: @max_length, count: :codepoints)
    |> validate_length(:display, max: @max_length, count: :codepoints)
    |> unique_constraint([:account_id, :provider_id, :external_group_id],
      name: :sso_directory_groups_live_index
    )
  end

  @doc "A push with no displayName leaves the name the directory last gave it."
  def rename(%DirectoryGroup{} = group, nil), do: change(group, %{})

  def rename(%DirectoryGroup{display: display} = group, display), do: change(group, %{})

  def rename(%DirectoryGroup{} = group, display) do
    group
    |> change(display: display)
    |> validate_length(:display, max: @max_length, count: :codepoints)
  end

  def delete(%DirectoryGroup{} = group), do: change(group, deleted_at: DateTime.utc_now())

  defp require_external_id_or_display(changeset) do
    if blank?(get_field(changeset, :external_group_id)) do
      validate_required(changeset, [:display])
    else
      changeset
    end
  end

  defp blank?(value), do: is_nil(value) or value == ""
end
