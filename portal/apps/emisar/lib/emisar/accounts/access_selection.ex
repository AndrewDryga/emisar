defmodule Emisar.Accounts.AccessSelection do
  @moduledoc """
  The access half of a grant form's input changeset: which runners
  (`runner_access_mode` plus the `"group:<name>"` / `"runner:<id>"` values in
  `scope`) and which packs on them (`pack_access_mode` plus the `"pack:<id>"`
  values in `pack_scope`). The invitation and the service-account submissions
  share it, so both forms read ONE definition of a valid selection, and a crafted
  selector is a field error at the context boundary instead of a widened grant.
  """
  import Ecto.Changeset
  alias Emisar.Accounts.RunnerAccess

  @doc """
  Validates the selection on `changeset` against `allowlist` — the account's
  current `%{groups: _, runners: _, packs: _}` facts — and the reach `role` may
  carry.

  A valid selection puts the canonical `%RunnerAccess{}` in `:runner_access` and
  normalizes the four fields to it: a runner a chosen group already covers is
  dropped, and a role with no runner reach clears both dimensions. An empty
  selected-runner scope is a `:runner_access_mode` error; an empty or unknown pack
  selection is a `:pack_access_mode` error.
  """
  def validate(%Ecto.Changeset{} = changeset, allowlist, role) do
    changeset
    |> validate_inclusion(:runner_access_mode, modes())
    |> validate_inclusion(:pack_access_mode, pack_modes())
    |> put_runner_access(allowlist, role)
  end

  defp modes, do: Enum.map(RunnerAccess.modes(), &Atom.to_string/1)
  defp pack_modes, do: Enum.map(RunnerAccess.pack_modes(), &Atom.to_string/1)

  defp put_runner_access(changeset, allowlist, role) do
    mode = get_field(changeset, :runner_access_mode)
    scope = get_field(changeset, :scope) || []
    pack_mode = get_field(changeset, :pack_access_mode)
    pack_scope = get_field(changeset, :pack_scope) || []

    case RunnerAccess.from_selection(mode, scope, allowlist, pack_mode, pack_scope) do
      {:ok, selected} ->
        # The role decides what the selection may actually grant, so a role that
        # carries no reach resets it here rather than at the write — the form
        # re-renders from `:runner_access` and shows the operator the cleared
        # state before they send it.
        access = RunnerAccess.for_role(role, selected)

        changeset
        |> put_change(:scope, RunnerAccess.selection_values(access.groups, access.runner_ids))
        |> put_change(:pack_scope, RunnerAccess.pack_selection_values(access.pack_ids))
        |> put_change(:runner_access, access)
        |> put_change(:runner_access_mode, to_string(access.mode))
        |> put_change(:pack_access_mode, to_string(access.pack_mode))

      {:error, :invalid_pack_access} ->
        add_error(changeset, :pack_access_mode, "requires at least one available pack")

      {:error, :invalid_runner_access} ->
        add_error(changeset, :runner_access_mode, "requires at least one runner group or runner")
    end
  end
end
