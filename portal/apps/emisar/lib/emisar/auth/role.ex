defmodule Emisar.Auth.Role do
  @moduledoc """
  The canonical set of account membership roles — the single source of
  truth for the `Membership` schema's `Ecto.Enum` and the team UI's role
  list. Authorization compares *permissions* (`Authorizer.covers_role?/2`),
  never role rank — there is deliberately no rank/`at_least?` here.

  Listed most-privileged first (the order the team UI renders). Actor-kind
  roles that aren't account memberships (`:api_client`, `:runner`,
  `:system`) live on `Auth.Subject`, not here.
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
end
