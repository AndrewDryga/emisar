defmodule EmisarWeb.PermissionsTest do
  @moduledoc """
  Unit tests for the role-based authorization matrix. The full matrix
  is asserted here so a change to `EmisarWeb.Permissions` immediately
  fails CI if it accidentally widens or narrows a role.
  """

  use ExUnit.Case, async: true

  alias EmisarWeb.Permissions

  # Each row: {action, [allowed roles]}
  @matrix [
    {:manage_billing, [:owner]},
    {:manage_subscription, [:owner]},
    {:manage_team, [:owner, :admin]},
    {:manage_auth_keys, [:owner, :admin]},
    {:manage_api_keys, [:owner, :admin]},
    {:manage_policies, [:owner, :admin]},
    {:manage_runbooks, [:owner, :admin]},
    {:manage_runners, [:owner, :admin]},
    {:dispatch_run, [:owner, :admin, :operator]},
    {:cancel_run, [:owner, :admin, :operator]},
    {:decide_approval, [:owner, :admin, :operator]},
    {:view, [:owner, :admin, :operator, :viewer]},
    {:view_audit, [:owner, :admin, :operator, :viewer]}
  ]

  for {action, allowed_roles} <- @matrix do
    for role <- [:owner, :admin, :operator, :viewer] do
      should_pass = role in allowed_roles
      direction = if should_pass, do: "allows", else: "denies"

      test "#{direction} role=#{role} for action=#{action}" do
        assigns = %{current_membership: %Emisar.Accounts.Membership{role: unquote(role)}}
        assert Permissions.can?(assigns, unquote(action)) == unquote(should_pass)
      end
    end
  end

  test "nil membership denies everything" do
    refute Permissions.can?(%{current_membership: nil}, :view)
    refute Permissions.can?(%{current_membership: nil}, :manage_team)
  end

  test "unknown role denies everything" do
    refute Permissions.can?(
             %{current_membership: %Emisar.Accounts.Membership{role: :intern}},
             :view
           )
  end

  test "unknown action denies everything (default-deny)" do
    refute Permissions.can?(
             %{current_membership: %Emisar.Accounts.Membership{role: :owner}},
             :explode_database
           )
  end

  test "accepts socket-shaped %{assigns: ...} input" do
    socket = %{
      assigns: %{current_membership: %Emisar.Accounts.Membership{role: :owner}}
    }

    assert Permissions.can?(socket, :manage_billing)
  end

  describe "gated/3" do
    test "runs the function when allowed" do
      socket = %{
        assigns: %{current_membership: %Emisar.Accounts.Membership{role: :owner}}
      }

      result = Permissions.gated(socket, :manage_billing, fn _ -> {:noreply, :allowed} end)
      assert result == {:noreply, :allowed}
    end

    # Flash assertion against gated/3 requires a real LiveView socket
    # (force_assign uses internal Phoenix.LiveView state). Covered by
    # integration tests that hit each LiveView through `live/3`. The
    # `can?/2` matrix above already proves the denial side.
  end
end
