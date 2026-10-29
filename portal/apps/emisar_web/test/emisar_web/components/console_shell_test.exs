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

    defp render_shell_as(assigns, role, section \\ :dashboard) do
      membership = %{assigns.current_membership | role: role}

      assigns =
        assigns
        |> Map.put(:current_membership, membership)
        |> Map.put(:current_subject, Subject.for_member(membership, assigns.current_account))
        |> Map.put(:section, section)

      rendered_to_string(~H"""
      <ShellComponents.console_shell
        current_account={@current_account}
        current_membership={@current_membership}
        current_subject={@current_subject}
        chrome={@chrome}
        section={@section}
      >
        <:title>Console</:title>
        Content
      </ShellComponents.console_shell>
      """)
    end

    # Group headings and link labels of the desktop sidebar, in order.
    defp sidebar(html) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("nav.scrollbar-subtle")
      |> Enum.at(0)
      |> LazyHTML.query("p, a span.flex-1")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    end

    test "groups the sidebar into Connect, Operate, and Control", %{assigns: assigns} do
      assert sidebar(render_shell_as(assigns, :admin)) == [
               "Dashboard",
               "Connect",
               "Runners",
               "AI agents",
               "Service accounts",
               "Operate",
               "Runs",
               "Runbooks",
               "Approvals",
               "Audit log",
               "Control",
               "Policy",
               "Packs",
               "Team",
               "Billing",
               "Resources",
               "Docs",
               "Changelog",
               "Status"
             ]
    end

    test "a billing manager sees only links they can open, each under its group", %{
      assigns: assigns
    } do
      # The finance seat can read the audit log, so Operate shows with that
      # one link; Runs, Runbooks, Approvals, Policy, and Packs stay hidden.
      assert sidebar(render_shell_as(assigns, :billing_manager)) == [
               "Connect",
               "Service accounts",
               "Operate",
               "Audit log",
               "Control",
               "Team",
               "Billing",
               "Resources",
               "Docs",
               "Changelog",
               "Status"
             ]
    end

    test "the moved links stay active on their own sections", %{assigns: assigns} do
      for {section, path} <- [
            runbooks: "runbooks",
            service_accounts: "settings/service-accounts",
            audit: "audit"
          ] do
        classes =
          assigns
          |> render_shell_as(:admin, section)
          |> LazyHTML.from_fragment()
          |> LazyHTML.query(~s(a[href="/app/both-connected/#{path}"]))
          |> LazyHTML.attribute("class")

        assert [_ | _] = classes
        assert Enum.all?(classes, &(&1 =~ "font-medium text-zinc-50"))
      end
    end
  end
end
