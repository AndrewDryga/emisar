defmodule EmisarWeb.Components.ConsoleShellTest do
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias Emisar.Accounts
  alias Emisar.Auth.Subject
  alias EmisarWeb.{ShellChrome, ShellComponents}

  describe "console_shell/1" do
    setup do
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

      membership = %Accounts.Membership{
        id: "01995e70-5a00-7000-8000-000000000004",
        account_id: current_account.id,
        email: "demo@emisar.dev",
        display_name: "Maya Chen",
        role: :owner
      }

      assigns = %{
        current_account: current_account,
        current_membership: membership,
        current_subject: Subject.for_member(membership, current_account),
        chrome: %ShellChrome{switchable_accounts: [current_account, other_account]}
      }

      %{assigns: assigns}
    end

    defp render_shell(assigns) do
      rendered_to_string(~H"""
      <ShellComponents.console_shell
        current_account={@current_account}
        current_membership={@current_membership}
        current_subject={@current_subject}
        chrome={@chrome}
      >
        <:title>Dashboard</:title>
        Dashboard content
      </ShellComponents.console_shell>
      """)
    end

    test "marks the current workspace with the selected square avatar", %{assigns: assigns} do
      html = render_shell(assigns)

      assert [_, _] = Regex.scan(~r/rounded-xs bg-brand-500 text-zinc-950/, html)
      refute Regex.match?(~r/data-icon="state.selected"/, html)
    end

    test "switches by plain links to the other signed-in workspaces and offers more", %{
      assigns: assigns
    } do
      document = assigns |> render_shell() |> LazyHTML.from_fragment()

      links = fn href ->
        document |> LazyHTML.query(~s(a[href="#{href}"])) |> LazyHTML.text()
      end

      assert links.("/app/northstar") =~ "Northstar Labs"

      # The current workspace heads the menu; it is not a link to itself.
      switcher_links =
        document |> LazyHTML.query("ul.scrollbar-subtle a") |> Enum.map(&LazyHTML.text/1)

      assert Enum.any?(switcher_links, &(&1 =~ "Northstar Labs"))
      refute Enum.any?(switcher_links, &(&1 =~ "Both Connected Co"))
      assert links.("/sign_in") =~ "Sign in to a workspace"
      assert links.("/sign_up") =~ "Create new workspace"
      # No server-side switch: nothing posts to change workspaces.
      assert document |> LazyHTML.query("form[action*=switch]") |> Enum.count() == 0
    end

    test "names the signed-in Member, without an email confirmation banner", %{
      assigns: assigns
    } do
      html = render_shell(assigns)

      assert html =~ "Maya Chen"
      refute html =~ "Verify your email"
      refute html =~ "Resend email"
    end
  end
end
