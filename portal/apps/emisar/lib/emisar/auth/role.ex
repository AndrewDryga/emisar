defmodule Emisar.Auth.Role do
  @moduledoc """
  The canonical set of account membership roles and their privilege
  hierarchy — the single source of truth. The `Membership` schema's
  `Ecto.Enum`, the role-rank comparisons in `Accounts`, and the team
  UI's role list all read from here.

  Ordered most-privileged first; a lower rank means more privilege.
  Actor-kind roles that aren't account memberships (`:api_client`,
  `:runner`, `:system`) live on `Auth.Subject`, not here.
  """
  @roles [:owner, :admin, :operator, :viewer]

  @doc "All assignable membership roles, most-privileged first."
  def all, do: @roles

  @doc """
  Coerce a role name (atom or string) into a known role atom. Returns
  `{:ok, role}` or `:error`. Safe on untrusted input — it compares
  against the known set and never creates atoms.
  """
  def cast(role) when role in @roles, do: {:ok, role}

  def cast(role) when is_binary(role) do
    case Enum.find(@roles, &(Atom.to_string(&1) == role)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  def cast(_), do: :error

  @doc "True when `role` carries at least as much privilege as `required`."
  def at_least?(role, required) when role in @roles and required in @roles,
    do: rank(role) <= rank(required)

  def at_least?(_, _), do: false

  defp rank(role), do: Enum.find_index(@roles, &(&1 == role))
end
