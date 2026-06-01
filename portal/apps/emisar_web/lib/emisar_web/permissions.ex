defmodule EmisarWeb.Permissions do
  @moduledoc """
  Role-based authorization for LiveView event handlers and template
  visibility. The role hierarchy is owner > admin > operator > viewer.

      can?(socket, :manage_team)
      can?(socket, :dispatch_run)

  Each rule is matched against `socket.assigns.current_membership.role`.
  Missing membership → no permissions. The fallback `_` clause returns
  `false` so anything new defaults to deny until we add it.
  """

  alias Emisar.Accounts.Membership

  @type socket_or_assigns ::
          %{assigns: %{current_membership: Membership.t() | nil}}
          | %{current_membership: Membership.t() | nil}

  # -- Permission catalogue -------------------------------------------

  @doc """
  Returns true if the caller may perform `action`. The caller must have
  loaded `current_membership` (the UserAuth plug does this for /app routes).
  """
  def can?(socket_or_assigns, action) do
    role = role(socket_or_assigns)
    role && allow?(role, action)
  end

  # owner-only
  defp allow?("owner", :manage_billing), do: true
  defp allow?("owner", :manage_subscription), do: true

  # admin+
  defp allow?(role, :manage_team) when role in ~w(owner admin), do: true
  defp allow?(role, :manage_auth_keys) when role in ~w(owner admin), do: true
  defp allow?(role, :manage_api_keys) when role in ~w(owner admin), do: true
  defp allow?(role, :manage_policies) when role in ~w(owner admin), do: true
  defp allow?(role, :manage_runbooks) when role in ~w(owner admin), do: true
  defp allow?(role, :manage_runners) when role in ~w(owner admin), do: true

  # operator+
  defp allow?(role, :dispatch_run) when role in ~w(owner admin operator), do: true
  defp allow?(role, :cancel_run) when role in ~w(owner admin operator), do: true
  defp allow?(role, :decide_approval) when role in ~w(owner admin operator), do: true
  defp allow?(role, :execute_runbook) when role in ~w(owner admin operator), do: true

  # viewer+
  defp allow?(role, :view) when role in ~w(owner admin operator viewer), do: true
  defp allow?(role, :view_audit) when role in ~w(owner admin operator viewer), do: true
  defp allow?(role, :edit_own_profile) when role in ~w(owner admin operator viewer), do: true

  # default-deny
  defp allow?(_role, _action), do: false

  # -- Internals ------------------------------------------------------

  defp role(%{assigns: %{current_membership: %Membership{role: r}}}), do: r
  defp role(%{current_membership: %Membership{role: r}}), do: r
  defp role(_), do: nil

  @doc """
  Guard for `handle_event/3`. Returns either `{:ok, socket}` to proceed
  or `{:deny, socket_with_flash}` so the caller can short-circuit.

      with {:ok, socket} <- Permissions.require!(socket, :manage_auth_keys) do
        # ...
      end
  """
  def require!(socket, action) do
    if can?(socket, action) do
      {:ok, socket}
    else
      {:deny, Phoenix.LiveView.put_flash(socket, :error, denial_message(action))}
    end
  end

  defp denial_message(:manage_billing), do: "Only owners can manage billing."
  defp denial_message(:manage_subscription), do: "Only owners can change the subscription."
  defp denial_message(:manage_team), do: "Only owners and admins can manage the team."
  defp denial_message(:manage_auth_keys), do: "Only owners and admins can manage auth keys."
  defp denial_message(:manage_api_keys), do: "Only owners and admins can manage API keys."
  defp denial_message(:manage_policies), do: "Only owners and admins can manage policies."
  defp denial_message(:manage_runbooks), do: "Only owners and admins can manage runbooks."
  defp denial_message(:manage_runners), do: "Only owners and admins can manage runners."
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
