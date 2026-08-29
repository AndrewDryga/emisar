defmodule EmisarWeb.RoleCopy do
  @moduledoc """
  Shared confirm-dialog copy for a membership role change — the escalation
  QUESTION (title) and its CONSEQUENCE (body). The Team roster and the SSO
  synced-members list both grant the same privilege, so both read it the same
  way through here rather than keeping divergent copies.
  """
  alias Emisar.Auth

  @doc "The confirm-dialog title asking to grant `role` to `name`."
  def change_title(name, "owner"), do: "Make #{name} an owner?"
  def change_title(name, "admin"), do: "Make #{name} an admin?"
  def change_title(name, "billing_manager"), do: "Make #{name} a billing manager?"
  def change_title(name, "operator"), do: "Make #{name} an operator?"
  def change_title(name, role), do: "Change #{name} to #{Auth.role_label(role)}?"

  @doc """
  The confirm-dialog body for granting `role`. Promoting to a privileged role
  grants real power (a new owner can act against you), so those spell it out;
  every other role states its OWN contract from the one description the role
  pickers already render.
  """
  def change_body("owner") do
    "Owners have full control — billing, deleting the account, and managing other owners — and can remove or demote you."
  end

  def change_body("admin") do
    "Admins manage runners, policy, members, approvals, and billing across the whole account — everything an owner can, except adding or removing owners."
  end

  def change_body("operator"),
    do: "Operators can dispatch runs to your fleet and approve gated actions."

  def change_body(role), do: Auth.role_description(role)
end
