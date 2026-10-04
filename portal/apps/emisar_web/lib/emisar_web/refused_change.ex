defmodule EmisarWeb.RefusedChange do
  @moduledoc """
  Operator copy for a SCIM change emisar refused: what did not happen, and what
  to fix. The connection page and the audit trail both read it, so one refusal
  says the same thing on both. Accepts the domain's atoms and the strings an
  audit payload stores.
  """

  @spec outcome(atom() | String.t()) :: String.t()
  def outcome(change) when is_atom(change), do: change |> Atom.to_string() |> outcome()
  def outcome("add_user"), do: "Not added"
  def outcome("update_user"), do: "Not updated"
  def outcome("suspend_user"), do: "Not suspended"
  def outcome("add_group"), do: "Group not added"
  def outcome("update_group"), do: "Group not updated"
  def outcome("remove_group"), do: "Group not removed"
  def outcome(_change), do: "Not applied"

  @spec reason(atom() | String.t()) :: String.t()
  def reason(reason) when is_atom(reason), do: reason |> Atom.to_string() |> reason()

  def reason("last_owner") do
    "This is the workspace's last active owner. Make someone else an owner, then retry in your identity provider."
  end

  def reason("member_email_taken") do
    "Another member of this workspace already uses this email address. Remove that member, or change the address in your directory."
  end

  def reason("identity_pending_approval") do
    "This email belongs to an existing member. Approve the request under Pending access requests on the Team page."
  end

  def reason("invitation_pending") do
    "This person has an open invitation. They must accept it before the directory can add them."
  end

  def reason("identifier_taken") do
    "Someone else on this connection already has this externalId. Check the externalId mapping in your identity provider."
  end

  def reason("unsupported_scim_patch") do
    "The update changed an attribute emisar does not sync. Remove that attribute from your provider's attribute mapping."
  end

  def reason("invalid_scim_active"), do: "The update's active value was not true or false."

  def reason("too_many_scim_operations"), do: "The update carried more than 100 operations."

  def reason("invalid_scim_group") do
    "The group change was malformed or too large, such as more than 5,000 members or a value over 255 characters."
  end

  def reason("invalid_value"),
    do: "A value was missing, malformed, or too long. Check these attributes in your directory."

  def reason(_reason), do: "emisar could not apply this change."
end
