defmodule EmisarWeb.GroupAccessForm do
  @moduledoc "Selector presentation for group additions and connection defaults."
  alias Emisar.{Accounts, SSO}

  def runner_values(access),
    do: Accounts.runner_access_selection_values(access.groups, access.runner_ids)

  def pack_values(access), do: Accounts.pack_access_selection_values(access.pack_ids)
  def pack_mode(%{mode: :none}), do: "none"
  def pack_mode(%{pack_mode: :restricted, pack_ids: []}), do: "none"
  def pack_mode(access), do: to_string(access.pack_mode)

  def presentation(default, changeset) do
    runner_mode = to_string(Ecto.Changeset.get_field(changeset, :runner_access_mode))

    pack_mode =
      if Ecto.Changeset.get_field(changeset, :pack_access_mode) == :restricted and
           Ecto.Changeset.get_field(changeset, :pack_scope_pack_ids) == [] and
           not Keyword.has_key?(changeset.errors, :pack_access_mode),
         do: "none",
         else: to_string(Ecto.Changeset.get_field(changeset, :pack_access_mode))

    SSO.group_access_selection(default, %{
      "runner_access_mode" => runner_mode,
      "scope" => List.wrap(Ecto.Changeset.get_field(changeset, :scope)),
      "pack_access_mode" => pack_mode,
      "pack_scope" => List.wrap(Ecto.Changeset.get_field(changeset, :pack_scope))
    })
  end
end
