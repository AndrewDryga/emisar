defmodule EmisarWeb.MemberErrors do
  @moduledoc "The single source of the sentence shown when a membership change is refused — consumed by the Team roster and the SSO settings roster."

  # Team and SSO settings both administer the same memberships through the same
  # Accounts functions, and each had grown its own mapping of the same domain
  # error atoms. They said different things for the same refusal — and for
  # :insufficient_privileges they said different THINGS: the no-escalation rule
  # is `for_role(role) ⊆ subject.permissions`, a permission-subset check, so
  # "a member whose role is equal to or above yours" described a rank comparison
  # the domain does not implement.
  #
  # message/1 raises on an unmapped atom, so a new domain error cannot reach an
  # operator as a generic "that didn't apply" from one page and a real sentence
  # from the other.
  @messages %{
    unauthorized: "Only owners and admins can manage members.",
    insufficient_privileges:
      "You can only assign or change roles whose permissions you already hold.",
    last_owner: "Can't remove or demote the last owner. Promote someone else first.",
    cannot_self_promote: "Promote someone else first — you can't promote yourself.",
    cannot_modify_self: "You can't change your own membership from here. Use Profile.",
    not_found: "That member no longer exists.",
    directory_managed_profile:
      "This member's name is managed by your identity provider — change it there.",
    role_managed_by_directory: "That member's role is set by their identity provider.",
    runner_access_managed_by_directory:
      "That member's runner access is set by their identity provider.",
    runner_access_exceeds_subject: "You can only grant runner access that you currently have.",
    member_runner_access_exceeds_subject:
      "That member's runner access is wider than yours. Narrow their access first, then change their role.",
    mfa_enrollment_required:
      "Enable 2FA on your own profile first — otherwise you'd lock yourself out.",
    deactivated_in_idp:
      "That member is deactivated in your identity provider — reactivate them there first."
  }

  @invalid "That change wasn't valid. Refresh to see the member's current state, then try again."
  @unknown "That change didn't apply. Refresh to see the member's current state, then try again."

  @doc "The operator-facing sentence for one refused membership change."
  @spec message(term()) :: String.t()
  def message(%Ecto.Changeset{}), do: @invalid

  def message(reason) when is_atom(reason) do
    case Map.fetch(@messages, reason) do
      {:ok, message} -> message
      # A domain error nobody has worded yet still has to reach the operator as
      # something actionable rather than crashing the page.
      :error -> @unknown
    end
  end

  def message(_reason), do: @unknown

  @doc "Every reason with a written sentence, for the test that pins them."
  @spec reasons() :: [atom()]
  def reasons, do: Map.keys(@messages)
end
