defmodule EmisarWeb.AcceptInvitationLiveTest do
  @moduledoc """
  The invitation page (plan §3 "Invitations"): an invitation names an address
  and a pending Member, and whoever proves that address in this browser joins as
  that Member. Two states: unavailable, or the name form, which posts to the
  invitation's code request; the code goes to the invited address only, and
  using it in this browser accepts the invitation and adds that workspace's
  session. Nothing is accepted before the code completes, so a forwarded link
  changes nothing. (An SSO-only workspace's continue-with-SSO step is in
  `SSOControllerTest`.)
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Auth, Repo}

  @code_link ~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})"

  defp invite(owner, attrs \\ %{}) do
    email = "invitee-#{System.unique_integer([:positive])}@example.com"

    {:ok, %{membership: invitation, invitation_token: token}} =
      Accounts.invite_user_to_account(
        Fixtures.Accounts.invitation_attrs(
          Map.merge(%{email: email, role: "operator", runner_access_mode: "all"}, attrs)
        ),
        Fixtures.Subjects.subject_for(owner)
      )

    {invitation, token}
  end

  # The armed form's POST: the invitation token and the name, never an address.
  defp request_code(conn, token, name),
    do: post(conn, ~p"/accept_invitation/#{token}", %{"member" => %{"display_name" => name}})

  defp complete(requested) do
    assert_received {:email, sent}
    [_, token_id, code] = Regex.run(@code_link, sent.text_body)
    {sent, requested |> recycle() |> get(~p"/sign_in/magic/#{token_id}/#{code}")}
  end

  describe "the token gate" do
    test "a bogus or blank token renders a cause-neutral unavailable page", %{conn: conn} do
      for token <- ["not-a-real-token", "   "] do
        {:ok, _lv, html} = live(conn, ~p"/accept_invitation/#{token}")

        # Inline state with a recovery action; it neither claims "expired" nor
        # names a workspace.
        assert html =~ "Invitation unavailable"
        assert html =~ "isn&#39;t valid or is no longer available"
        assert html =~ "Go to sign in"
        refute html =~ "expired"
      end
    end

    test "an expired invitation names the state and asks for a fresh one", %{conn: conn} do
      {_conn, owner, account} = register_and_log_in(conn)
      {invitation, token} = invite(owner)
      nine_days_ago = DateTime.add(DateTime.utc_now(), -9 * 24 * 3600, :second)
      invitation |> Ecto.Changeset.change(inserted_at: nine_days_ago) |> Repo.update!()

      {:ok, _lv, html} = live(build_conn(), ~p"/accept_invitation/#{token}")

      # The bearer holds the real emailed token, so naming the expiry is not an
      # enumeration oracle — but the page still names no workspace.
      assert html =~ "Invitation expired"
      assert html =~ "send a fresh one"
      refute html =~ account.name
    end
  end

  describe "accepting" do
    setup %{conn: conn} do
      {_conn, owner, account} = register_and_log_in(conn)
      {invitation, token} = invite(owner)
      %{owner: owner, account: account, invitation: invitation, token: token}
    end

    test "the join offer names the workspace, role and address; a valid name arms the code request and accepts nothing",
         %{account: account, invitation: invitation, token: token} do
      {:ok, lv, html} = live(build_conn(), ~p"/accept_invitation/#{token}")

      assert html =~ account.name
      # The human role label, never the raw atom.
      assert html =~ "Operator"
      assert html =~ invitation.email
      refute html =~ "password"

      form = form(lv, "#accept_form", %{"member" => %{"display_name" => "New Person"}})
      assert render_submit(form) =~ "phx-trigger-action"
      assert has_element?(lv, ~s(#accept_form[action="/accept_invitation/#{token}"]))

      # Nothing is accepted until the invited address's code is used here.
      assert Repo.reload!(invitation) == invitation
      assert {:ok, _still_pending} = Accounts.fetch_invitation_by_token(token)
    end

    test "the invitee finishes with the emailed code and opens the workspace", %{
      account: account,
      invitation: invitation,
      token: token
    } do
      {:ok, lv, _html} = live(build_conn(), ~p"/accept_invitation/#{token}")
      form = form(lv, "#accept_form", %{"member" => %{"display_name" => "New Person"}})
      render_submit(form)

      requested = follow_trigger_action(form, build_conn())
      assert redirected_to(requested) == ~p"/sign_in/magic?sent=1"
      {sent, completed} = complete(requested)

      assert sent.to == [{"", invitation.email}]
      assert redirected_to(completed) == ~p"/app/#{account}"

      accepted = Repo.reload!(invitation)
      assert accepted.display_name == "New Person"
      assert %DateTime{} = accepted.invitation_accepted_at
      assert %DateTime{} = accepted.email_verified_at
      assert Accounts.fetch_invitation_by_token(token) == {:error, :not_found}

      [{account_id, session_token}] = get_session(completed, :sessions)
      assert account_id == account.id

      assert {:ok, %{membership_id: membership_id}} =
               Auth.fetch_session_by_token(session_token, account.id)

      assert membership_id == invitation.id
      assert html_response(get(recycle(completed), ~p"/app/#{account}"), 200) =~ "New Person"
    end

    test "a browser signed in to other workspaces gains one more session", %{
      account: account,
      token: token
    } do
      {elsewhere, _other_owner, other_account} = register_and_log_in(build_conn())

      {_sent, completed} = elsewhere |> request_code(token, "Joiner") |> complete()

      assert redirected_to(completed) == ~p"/app/#{account}"

      assert get_session(completed, :sessions) |> Enum.map(&elem(&1, 0)) == [
               other_account.id,
               account.id
             ]
    end

    test "a forwarded link opened in another browser changes nothing", %{
      invitation: invitation,
      token: token
    } do
      # The holder submits a name; the code goes to the invited mailbox only.
      _holder = request_code(build_conn(), token, "Holder Name")
      assert_received {:email, holder_sent}
      assert holder_sent.to == [{"", invitation.email}]
      assert Repo.reload!(invitation) == invitation

      # The invitee still joins from their own browser, exactly once.
      {_sent, completed} = build_conn() |> request_code(token, "Real Name") |> complete()

      assert [_entry] = get_session(completed, :sessions)
      assert Repo.reload!(invitation).display_name == "Real Name"
      assert Accounts.fetch_invitation_by_token(token) == {:error, :not_found}
    end

    test "a crafted payload naming another address still mails only the invited one", %{
      invitation: invitation,
      token: token
    } do
      {:ok, lv, _html} = live(build_conn(), ~p"/accept_invitation/#{token}")

      crafted = %{
        "user" => %{"email" => "attacker@evil.test"},
        "member" => %{"email" => "attacker@evil.test", "display_name" => "New Person"}
      }

      render_submit(lv, "accept", crafted)
      post(build_conn(), ~p"/accept_invitation/#{token}", crafted)

      assert_received {:email, sent}
      assert sent.to == [{"", invitation.email}]
      refute_received {:email, _another}
    end

    test "an accept that lost the race to the invitee's other browser lands on the terminal state",
         %{token: token} do
      {:ok, lv, _html} = live(build_conn(), ~p"/accept_invitation/#{token}")
      {_sent, _completed} = build_conn() |> request_code(token, "First Browser") |> complete()

      html =
        lv
        |> form("#accept_form", %{"member" => %{"display_name" => "Second Browser"}})
        |> render_submit()

      # Terminal state with a recovery action, never a flash over a form that
      # can no longer succeed.
      assert html =~ "Invitation unavailable"
      assert html =~ "Go to sign in"
      refute html =~ "accept_form"
    end

    test "a mounted old link cannot accept after an administrator resends", %{
      owner: owner,
      invitation: invitation,
      token: old_token
    } do
      {:ok, old_live, _html} = live(build_conn(), ~p"/accept_invitation/#{old_token}")

      assert {:ok, %{invitation_token: new_token}} =
               Accounts.resend_account_invitation(
                 invitation,
                 Fixtures.Subjects.subject_for(owner)
               )

      old_html =
        old_live
        |> form("#accept_form", %{"member" => %{"display_name" => "Old Link"}})
        |> render_submit()

      assert old_html =~ "Invitation unavailable"

      {:ok, new_live, _html} = live(build_conn(), ~p"/accept_invitation/#{new_token}")

      new_html =
        new_live
        |> form("#accept_form", %{"member" => %{"display_name" => "New Link"}})
        |> render_submit()

      assert new_html =~ "phx-trigger-action"
    end

    test "an invitation rotated after the code was sent fails closed at completion", %{
      owner: owner,
      invitation: invitation,
      token: token
    } do
      requested = request_code(build_conn(), token, "Late Name")

      assert {:ok, _resent} =
               Accounts.resend_account_invitation(
                 invitation,
                 Fixtures.Subjects.subject_for(owner)
               )

      {_sent, refused} = complete(requested)

      assert redirected_to(refused) == ~p"/sign_in"
      assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "can no longer be accepted"
      refute get_session(refused, :sessions)
      assert is_nil(Repo.reload!(invitation).invitation_accepted_at)
    end

    test "an invitation revoked before the code is requested sends nothing", %{
      invitation: invitation,
      token: token
    } do
      {:ok, lv, _html} = live(build_conn(), ~p"/accept_invitation/#{token}")
      Fixtures.Memberships.mark_membership_as_deleted(invitation)

      html =
        lv
        |> form("#accept_form", %{"member" => %{"display_name" => "Too Late"}})
        |> render_submit()

      assert html =~ "Invitation unavailable"

      refused = request_code(build_conn(), token, "Too Late")
      assert redirected_to(refused) == ~p"/accept_invitation/#{token}"
      refute_received {:email, _code}
    end

    test "an address that is a Member elsewhere joins as a new Member of this workspace", %{
      owner: owner,
      account: account
    } do
      {_conn, elsewhere, _other_account} =
        register_and_log_in(build_conn(), %{member: %{display_name: "Elsewhere Name"}})

      {invitation, token} = invite(owner, %{email: elsewhere.email})

      {:ok, _lv, html} = live(build_conn(), ~p"/accept_invitation/#{token}")
      refute html =~ "Elsewhere Name"

      {_sent, completed} = build_conn() |> request_code(token, "Work Name") |> complete()

      assert redirected_to(completed) == ~p"/app/#{account}"
      assert Repo.reload!(invitation).display_name == "Work Name"
      # One address, two Members: the other workspace's Member is untouched.
      assert Repo.reload!(elsewhere) == elsewhere
    end
  end
end
