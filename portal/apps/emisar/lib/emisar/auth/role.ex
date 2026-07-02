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
  One-line description of what a role can do — the shared copy behind every
  role picker (team invite, SSO default role, group→role mapping). Accepts an
  atom or string; an unknown role has no description (`nil`).
  """
  def description(role) when is_atom(role), do: role |> Atom.to_string() |> description()

  def description("owner"),
    do: "Full control of the workspace, including billing and adding or removing other owners."

  def description("admin"),
    do: "Manages members, runners, and policies, and approves actions. Billing is view-only."

  def description("billing_manager"),
    do: "Manages the subscription, payment method, and invoices — no team, runners, or actions."

  def description("operator"),
    do: "Dispatches actions and approves them. No team, policy, or billing management."

  def description("viewer") do
    "Read-only across runs, runners, approvals, and audit — can't dispatch or change anything."
  end

  def description(_), do: nil

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
