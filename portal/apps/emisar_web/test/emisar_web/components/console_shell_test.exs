defmodule EmisarWeb.Components.ConsoleShellTest do
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias Emisar.{Accounts, Users}
  alias Emisar.Auth.Subject
  alias EmisarWeb.CoreComponents

  describe "console_shell/1" do
    test "renders the current workspace with the selected square avatar" do
      current_account = %Accounts.Account{
        id: "01995e70-5a00-7000-8000-000000000001",
        name: "Both Connected Co",
        slug: "both-connected"
      }

      other_account = %Accounts.Account{
        id: "01995e70-5a00-7000-8000-000000000002",
        name: "Northstar Labs",
        slug: "northstar"
      }

      user = %Users.User{
        id: "01995e70-5a00-7000-8000-000000000003",
        email: "demo@emisar.dev",
        full_name: "Maya Chen",
        confirmed_at: DateTime.utc_now()
      }

      membership = %Accounts.Membership{
        id: "01995e70-5a00-7000-8000-000000000004",
        account_id: current_account.id,
        user_id: user.id,
        role: :owner
      }

      assigns = %{
        current_account: current_account,
        current_subject: Subject.for_user(user, current_account, membership),
        current_user: user,
        switchable_accounts: [current_account, other_account]
      }

      html =
        rendered_to_string(~H"""
        <CoreComponents.console_shell
          current_account={@current_account}
          current_subject={@current_subject}
          current_user={@current_user}
          switchable_accounts={@switchable_accounts}
        >
          <:title>Dashboard</:title>
          Dashboard content
        </CoreComponents.console_shell>
        """)

      assert [_, _] = Regex.scan(~r/bg-brand-500 text-zinc-950/, html)
      refute Regex.match?(~r/data-icon="state.selected"/, html)
      assert [_, _] = Regex.scan(~r/rounded-sm bg-brand-500 text-zinc-950/, html)
    end
  end
end
