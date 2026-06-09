defmodule EmisarWeb.Permissions do
  @moduledoc """
  Permission-based authorization for LiveView event handlers and template
  visibility.

      can?(socket, :manage_team)
      can?(socket, :dispatch_run)

  Each UI action maps to the backend permission it requires; the check is a
  membership of the caller's permission set. The role → permission mapping
  itself lives once, in the context Authorizers — this module never branches
  on a role name, so it can't drift from the backend the way a duplicated
  role table would.

  Reads `current_subject` (its permissions are computed once at mount) when
  present, falling back to `permissions_for(current_membership.role)`. Missing
  both → no permissions. An unknown action maps to no permission, so anything
  new defaults to deny until it's added here.
  """

  alias Emisar.Auth.{Authorizer, Subject}

  alias Emisar.{
    Accounts,
    ApiKeys,
    Approvals,
    Audit,
    Billing,
    Catalog,
    Policies,
    Runbooks,
    Runners,
    Runs
  }

  alias Emisar.Accounts.Membership

  # -- Permission catalogue -------------------------------------------

  @doc """
  Returns true if the caller's permissions include the one `action` requires.
  The caller must have a `current_subject` or `current_membership` in assigns
  (the UserAuth plug loads these for /app routes).
  """
  def can?(socket_or_assigns, action) do
    permission = permission_for(action)
    permissions = permissions(socket_or_assigns)

    not is_nil(permission) and not is_nil(permissions) and
      MapSet.member?(permissions, permission)
  end

  # UI verb → the backend permission it requires. The role coverage of each
  # permission is defined by the context Authorizers' list_permissions_for_role/1.
  defp permission_for(:manage_billing), do: Billing.Authorizer.manage_billing_permission()
  defp permission_for(:manage_subscription), do: Billing.Authorizer.manage_billing_permission()

  defp permission_for(:manage_account_security),
    do: Accounts.Authorizer.manage_security_settings_permission()

  defp permission_for(:manage_team), do: Accounts.Authorizer.manage_team_permission()
  defp permission_for(:manage_auth_keys), do: Runners.Authorizer.manage_auth_keys_permission()
  defp permission_for(:manage_api_keys), do: ApiKeys.Authorizer.manage_api_keys_permission()
  defp permission_for(:manage_policies), do: Policies.Authorizer.manage_policies_permission()
  defp permission_for(:manage_runbooks), do: Runbooks.Authorizer.manage_runbooks_permission()
  defp permission_for(:manage_runners), do: Runners.Authorizer.manage_runners_permission()
  defp permission_for(:manage_packs), do: Catalog.Authorizer.manage_catalog_permission()
  defp permission_for(:dispatch_run), do: Runs.Authorizer.dispatch_run_permission()
  defp permission_for(:cancel_run), do: Runs.Authorizer.cancel_run_permission()
  defp permission_for(:decide_approval), do: Approvals.Authorizer.decide_approval_permission()
  defp permission_for(:execute_runbook), do: Runs.Authorizer.dispatch_run_permission()
  defp permission_for(:view), do: Accounts.Authorizer.view_own_account_permission()
  defp permission_for(:view_audit), do: Audit.Authorizer.view_audit_permission()
  defp permission_for(:edit_own_profile), do: Accounts.Authorizer.edit_own_profile_permission()
  defp permission_for(_), do: nil

  # -- Internals ------------------------------------------------------

  defp permissions(%{assigns: assigns}), do: permissions(assigns)
  defp permissions(%{current_subject: %Subject{permissions: perms}}), do: perms

  defp permissions(%{current_membership: %Membership{role: role}}),
    do: Authorizer.permissions_for(role)

  defp permissions(_), do: nil

  defp denial_message(:manage_billing), do: "Only owners can manage billing."

  defp denial_message(:manage_account_security),
    do: "Only the account owner can change security settings."

  defp denial_message(:manage_subscription), do: "Only owners can change the subscription."
  defp denial_message(:manage_team), do: "Only owners and admins can manage the team."
  defp denial_message(:manage_auth_keys), do: "Only owners and admins can manage auth keys."
  defp denial_message(:manage_api_keys), do: "Only owners and admins can manage API keys."
  defp denial_message(:manage_policies), do: "Only owners and admins can manage policies."
  defp denial_message(:manage_runbooks), do: "Only owners and admins can manage runbooks."
  defp denial_message(:manage_runners), do: "Only owners and admins can manage runners."
  defp denial_message(:manage_packs), do: "Only owners and admins can manage packs."
  defp denial_message(:dispatch_run), do: "Viewers can't dispatch runs."
  defp denial_message(:cancel_run), do: "Viewers can't cancel runs."
  defp denial_message(:decide_approval), do: "Viewers can't decide approvals."
  defp denial_message(_), do: "You don't have permission to do that."

  @doc """
  Convenience wrapper for `handle_event/3`. If the caller has the
  permission, runs `fun.(socket)` and returns its `{:noreply, ...}`
  result; otherwise flashes the denial and short-circuits.

      def handle_event("revoke", params, socket) do
        Permissions.gated(socket, :manage_auth_keys, fn s -> do_revoke(s, params) end)
      end
  """
  def gated(socket, action, fun) do
    if can?(socket, action) do
      fun.(socket)
    else
      {:noreply, Phoenix.LiveView.put_flash(socket, :error, denial_message(action))}
    end
  end
end
