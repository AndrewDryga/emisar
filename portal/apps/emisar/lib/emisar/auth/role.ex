defmodule Emisar.Auth.Role do
  @moduledoc """
  The canonical set of account membership roles — the single source of
  truth for the `Membership` schema's `Ecto.Enum` and the team UI's role
  list. Authorization compares *permissions* (`Authorizer.covers_role?/2`),
  never role rank — there is deliberately no rank/`at_least?` here.

  Listed most-privileged first (the order the team UI renders). Actor-kind
  roles that aren't account memberships (`:api_client`, `:runner`) live on
  `Auth.Subject`, not here.

  `:billing_manager` is the one ORTHOGONAL role — full billing control,
  nothing else (a finance seat). It sorts after `:admin` for the UI but has
  no rank: permission comparison (`covers_role?/2`) is what makes an owner
  the only role able to grant it (only owners hold `manage_billing`).
  """
  @roles [:owner, :admin, :billing_manager, :operator, :viewer]

  @doc "All assignable membership roles, most-privileged first."
  def all, do: @roles

  @doc """
  Display label for a role (atom or string) — the one place multi-word roles
  get their human form, so no surface renders a raw `billing_manager`.
  Unknown strings capitalize as-is (legacy/renamed roles must still render).
  """
  def label(role) when is_atom(role), do: role |> Atom.to_string() |> label()
  def label("billing_manager"), do: "Billing manager"
  def label(role) when is_binary(role), do: String.capitalize(role)

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
