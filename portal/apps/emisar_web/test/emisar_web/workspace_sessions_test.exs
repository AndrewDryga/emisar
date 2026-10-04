defmodule EmisarWeb.WorkspaceSessionsTest do
  @moduledoc """
  The browser's workspace sessions (plan §3 "Sessions" and the §3.1 rows they
  pin): the `_emisar_web_key` cookie holds up to six `{account_id, token}`
  entries, one per workspace, and a request uses only the entry for the
  workspace its URL names. A sign-in renews the session and carries the other
  entries over; the entry it replaces, and the oldest one a seventh workspace
  pushes out, are revoked in the same request, so a copied cookie never keeps a
  credential this browser dropped. Sign-out ends every session the browser
  holds, in every workspace.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Audit.Event
  alias Emisar.{Auth, Crypto, Repo, RequestContext}
  alias Emisar.Auth.UserToken

  @cookie "_emisar_web_key"

  defp entry_accounts(conn),
    do: conn |> get_session(:sessions) |> List.wrap() |> Enum.map(&elem(&1, 0))

  defp session_row(token),
    do: token |> Crypto.hash() |> UserToken.Query.by_token_digest() |> Repo.one()

  defp audit_rows(account, event_type) do
    Event.Query.all()
    |> Event.Query.by_account_id(account.id)
    |> Event.Query.by_event_type(event_type)
    |> Repo.all()
  end

  # A fresh browser presenting exactly the cookie `conn`'s response set: what a
  # stolen or copied cookie looks like to the server.
  defp copy_cookie(conn) do
    %{value: value} = Map.fetch!(conn.resp_cookies, @cookie)
    Plug.Test.put_req_cookie(build_conn(), @cookie, value)
  end

  defp workspace_owner(attrs \\ %{}) do
    account = Fixtures.Accounts.create_account(attrs)

    owner =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        role: "owner",
        runner_access_mode: "all"
      )

    {owner, account}
  end

  describe "one cookie, several workspaces" do
    test "each workspace page authenticates only its own entry", %{conn: conn} do
      {conn, owner_a, account_a} = register_and_log_in(conn)
      {conn, owner_b, account_b} = register_and_log_in(conn)
      {_owner_c, account_c} = workspace_owner()

      assert entry_accounts(conn) == [account_a.id, account_b.id]

      a = get(conn, ~p"/app/#{account_a}")
      assert html_response(a, 200)
      assert a.assigns.current_membership.id == owner_a.id

      b = get(conn, ~p"/app/#{account_b}")
      assert html_response(b, 200)
      assert b.assigns.current_membership.id == owner_b.id

      # No entry for a third workspace: its sign-in, never another workspace's
      # session.
      c = get(conn, ~p"/app/#{account_c}")
      assert redirected_to(c) == ~p"/app/#{account_c}/sign_in"
    end

    test "the switcher lists every signed-in workspace and links to it", %{conn: conn} do
      {conn, _owner_a, account_a} = register_and_log_in(conn, %{account: %{name: "Alpha Ops"}})
      {conn, _owner_b, account_b} = register_and_log_in(conn, %{account: %{name: "Bravo Ops"}})

      {:ok, lv, _html} = live(conn, ~p"/app/#{account_a}")

      # The current workspace heads the menu; every other one is a plain link,
      # so switching is navigation, never a server-side switch.
      assert has_element?(lv, "li", "Alpha Ops")
      assert has_element?(lv, ~s(a[href="#{~p"/app/#{account_b}"}"]), "Bravo Ops")
      assert has_element?(lv, ~s(a[href="/sign_in"]), "Sign in to another workspace")
    end

    test "an entry for B carrying A's token is refused and leaves the cookie", %{conn: conn} do
      {owner_a, account_a} = workspace_owner()
      {_owner_b, account_b} = workspace_owner()
      token_a = Fixtures.Auth.create_session_token!(owner_a)
      forged = init_test_session(conn, %{sessions: [{account_b.id, token_a}]})

      assert Auth.fetch_session_by_token(token_a, account_b.id) == {:error, :not_found}
      assert {:error, {:redirect, %{to: to}}} = live(forged, ~p"/app/#{account_b}")
      assert to == ~p"/app/#{account_b}/sign_in"

      refused = get(forged, ~p"/app/#{account_b}")
      assert redirected_to(refused) == ~p"/app/#{account_b}/sign_in"
      assert get_session(refused, :sessions) == nil

      # Dropping the entry revokes the credential it carried, so no copy of this
      # cookie can present it again, under any workspace.
      assert Auth.fetch_session_by_token(token_a, account_a.id) == {:error, :not_found}
    end

    test "an unknown workspace 404s; a known one without an entry stores where to return", %{
      conn: conn
    } do
      {conn, _owner, _account} = register_and_log_in(conn)
      {_other_owner, other} = workspace_owner()

      assert_error_sent 404, fn -> get(conn, ~p"/app/no-such-workspace/runs") end

      sent = get(conn, ~p"/app/#{other}/runs?source=operator")
      assert redirected_to(sent) == ~p"/app/#{other}/sign_in"
      assert get_session(sent, :user_return_to) == ~p"/app/#{other}/runs?source=operator"

      # Only a GET is a destination worth returning to.
      posted = post(conn, ~p"/app/#{other}/mfa_setup/sso")
      assert redirected_to(posted) == ~p"/app/#{other}/sign_in"
      refute get_session(posted, :user_return_to)
    end
  end

  describe "a sign-in" do
    test "renews the session and CSRF token and keeps the other workspaces' entries", %{
      conn: conn
    } do
      {conn, _owner_a, account_a} = register_and_log_in(conn)
      {owner_b, account_b} = workspace_owner()

      # The sign-in page's form puts a CSRF token in the session.
      page = get(conn, ~p"/app/#{account_b}/sign_in")
      assert html_response(page, 200) =~ "_csrf_token"
      assert is_binary(get_session(page, "_csrf_token"))

      signed_in = email_link_sign_in(recycle(page), account_b, owner_b.email)

      assert redirected_to(signed_in) == ~p"/app/#{account_b}"
      assert entry_accounts(signed_in) == [account_a.id, account_b.id]
      # Nothing from before the sign-in survives the renewal: not the old CSRF
      # token, not the code's browser half.
      refute get_session(signed_in, "_csrf_token")
      refute get_session(signed_in, :magic_link_token_id)
      refute get_session(signed_in, :magic_link_nonce)

      browser = recycle(signed_in)
      assert html_response(get(browser, ~p"/app/#{account_a}"), 200)
      assert html_response(get(browser, ~p"/app/#{account_b}"), 200)
    end

    test "signing in to the same workspace again revokes the replaced token: a copied old cookie fails",
         %{conn: conn} do
      {owner, account} = workspace_owner()

      first = email_link_sign_in(conn, account, owner.email)
      old_copy = copy_cookie(first)
      [{_, old_token}] = get_session(first, :sessions)
      old_row = session_row(old_token)

      second = email_link_sign_in(recycle(first), account, owner.email)
      [{_, new_token}] = get_session(second, :sessions)

      assert new_token != old_token
      assert Auth.fetch_session_by_token(old_token, account.id) == {:error, :not_found}
      assert {:ok, _live} = Auth.fetch_session_by_token(new_token, account.id)

      assert [revoked] = audit_rows(account, "user.session_revoked")
      assert revoked.payload == %{"session_id" => old_row.id, "reason" => "replaced"}
      assert revoked.actor_id == owner.id

      assert redirected_to(get(old_copy, ~p"/app/#{account}")) == ~p"/app/#{account}/sign_in"
      assert html_response(get(recycle(second), ~p"/app/#{account}"), 200)
    end

    test "a seventh workspace evicts and revokes the oldest entry: a copied cookie loses it", %{
      conn: conn
    } do
      {conn, accounts} =
        Enum.reduce(1..6, {conn, []}, fn _n, {conn, accounts} ->
          {conn, _owner, account} = register_and_log_in(conn)
          {conn, accounts ++ [account]}
        end)

      [oldest, second_oldest | _rest] = accounts
      oldest_token = session_token(conn, oldest)
      {owner, seventh} = workspace_owner()

      # The browser's cookie before the seventh sign-in, as a copy would hold it.
      copy = get(conn, ~p"/app/#{oldest}") |> copy_cookie()

      signed_in = email_link_sign_in(conn, seventh, owner.email)

      assert entry_accounts(signed_in) == Enum.map(tl(accounts), & &1.id) ++ [seventh.id]
      assert Auth.fetch_session_by_token(oldest_token, oldest.id) == {:error, :not_found}

      assert [%Event{payload: %{"reason" => "evicted"}}] =
               audit_rows(oldest, "user.session_revoked")

      assert redirected_to(get(copy, ~p"/app/#{oldest}")) == ~p"/app/#{oldest}/sign_in"
      assert html_response(get(copy, ~p"/app/#{second_oldest}"), 200)
    end

    test "six entries and a 1024-byte return path stay under the 4 KB cookie limit", %{
      conn: conn
    } do
      conn =
        Enum.reduce(1..6, conn, fn _n, conn ->
          {conn, _owner, _account} = register_and_log_in(conn)
          conn
        end)

      {_owner, other} = workspace_owner()
      prefix = "/app/#{other.slug}/runs?source="
      return_to = prefix <> String.duplicate("x", 1024 - byte_size(prefix))

      sent = get(conn, return_to)

      assert redirected_to(sent) == ~p"/app/#{other}/sign_in"
      assert get_session(sent, :user_return_to) == return_to
      assert length(get_session(sent, :sessions)) == 6
      assert byte_size(sent.resp_cookies[@cookie].value) < 4096

      # A longer path falls back to the bare request path rather than overflow.
      sent = get(conn, return_to <> "y")
      assert get_session(sent, :user_return_to) == "/app/#{other.slug}/runs"
    end
  end

  describe "a dead entry" do
    test "removes only itself; the other workspaces keep working", %{conn: conn} do
      {conn, _owner_a, account_a} = register_and_log_in(conn)
      {conn, _owner_b, account_b} = register_and_log_in(conn)
      Fixtures.Auth.delete_session_token!(session_token(conn, account_a))

      dropped = get(conn, ~p"/app/#{account_a}")

      assert redirected_to(dropped) == ~p"/app/#{account_a}/sign_in"
      assert entry_accounts(dropped) == [account_b.id]
      assert html_response(get(recycle(dropped), ~p"/app/#{account_b}"), 200)
    end

    for revocation <- [:suspended, :identity_retired, :provider_disabled] do
      test "a #{revocation} SSO Member loses its workspace on HTTP and on LiveView remount", %{
        conn: conn
      } do
        {_owner, account, owner_subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
        provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
        member = Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")

        identity =
          Fixtures.SSO.create_user_identity(provider_id: provider.id, membership: member)

        conn = log_in_member(conn, member, auth_method: :sso, user_identity_id: identity.id)
        token = session_token(conn, account)
        rendered = get(conn, ~p"/app/#{account}")
        assert html_response(rendered, 200)

        case unquote(revocation) do
          :suspended ->
            topic = Auth.live_socket_topic(Crypto.hash(token))
            EmisarWeb.Endpoint.subscribe(topic)
            assert {:ok, _suspended} = Emisar.Accounts.suspend_membership(member, owner_subject)
            assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500

          :identity_retired ->
            Fixtures.SSO.retire_identity(identity)

          :provider_disabled ->
            Fixtures.SSO.disable_provider(provider)
        end

        assert {:error, {:redirect, %{to: to}}} = live(rendered)
        assert to == ~p"/app/#{account}/sign_in"

        dropped = get(conn, ~p"/app/#{account}")
        assert redirected_to(dropped) == ~p"/app/#{account}/sign_in"
        assert get_session(dropped, :sessions) == nil
        assert Auth.fetch_session_by_token(token, account.id) == {:error, :not_found}
        assert session_row(token) == nil
      end
    end
  end

  describe "sign-out" do
    test "DELETE /sign_out ends every entry's session, audits each Member and redirects each LiveView",
         %{conn: conn} do
      {conn, owner_a, account_a} = register_and_log_in(conn)
      {conn, owner_b, account_b} = register_and_log_in(conn)
      token_a = session_token(conn, account_a)
      token_b = session_token(conn, account_b)

      {:ok, lv_a, _html} = live(conn, ~p"/app/#{account_a}")
      {:ok, lv_b, _html} = live(conn, ~p"/app/#{account_b}")

      signed_out = delete(conn, ~p"/sign_out")

      assert redirected_to(signed_out) == ~p"/"
      assert get_session(signed_out, :sessions) == nil
      assert get_session(signed_out, :browser_id) == nil
      assert Auth.fetch_session_by_token(token_a, account_a.id) == {:error, :not_found}
      assert Auth.fetch_session_by_token(token_b, account_b.id) == {:error, :not_found}

      assert [%Event{actor_id: actor_a}] = audit_rows(account_a, "user.signed_out")
      assert actor_a == owner_a.id
      assert [%Event{actor_id: actor_b}] = audit_rows(account_b, "user.signed_out")
      assert actor_b == owner_b.id

      {to_a, _flash} = assert_redirect(lv_a, 1_000)
      assert URI.parse(to_a).path == ~p"/app/#{account_a}"
      {to_b, _flash} = assert_redirect(lv_b, 1_000)
      assert URI.parse(to_b).path == ~p"/app/#{account_b}"

      # The cookie the browser held before signing out reaches nothing now.
      assert redirected_to(get(conn, ~p"/app/#{account_a}")) == ~p"/app/#{account_a}/sign_in"
      assert redirected_to(get(conn, ~p"/app/#{account_b}")) == ~p"/app/#{account_b}/sign_in"
    end

    test "a copied cookie reaches only its signed-in workspaces; Profile revokes one; the owner's sign-out kills every copy",
         %{conn: conn} do
      {conn, owner_a, account_a} = register_and_log_in(conn)
      {conn, _owner_b, account_b} = register_and_log_in(conn)
      {_owner_c, account_c} = workspace_owner()
      stolen = get(conn, ~p"/app/#{account_a}") |> copy_cookie()

      assert html_response(get(stolen, ~p"/app/#{account_a}"), 200)
      assert html_response(get(stolen, ~p"/app/#{account_b}"), 200)
      assert redirected_to(get(stolen, ~p"/app/#{account_c}")) == ~p"/app/#{account_c}/sign_in"

      # From another device, the owner signs out the session the copy uses in A.
      stolen_row = session_row(session_token(conn, account_a))
      other_device = log_in_member(build_conn(), owner_a)
      {:ok, profile, _html} = live(other_device, ~p"/app/#{account_a}/settings/profile")
      render_click(profile, "revoke_session", %{"id" => stolen_row.id})

      assert redirected_to(get(stolen, ~p"/app/#{account_a}")) == ~p"/app/#{account_a}/sign_in"
      assert html_response(get(stolen, ~p"/app/#{account_b}"), 200)

      # The owner's own sign-out ends B for every copy of the cookie.
      assert redirected_to(delete(conn, ~p"/sign_out")) == ~p"/"
      assert redirected_to(get(stolen, ~p"/app/#{account_b}")) == ~p"/app/#{account_b}/sign_in"
    end
  end

  describe "the browser id (review revision 6)" do
    test "is minted when a sign-in starts and kept through every renewal until sign-out", %{
      conn: conn
    } do
      {owner_a, account_a} = workspace_owner()
      {owner_b, account_b} = workspace_owner()

      started =
        post(conn, ~p"/app/#{account_a}/sign_in/email", %{"user" => %{"email" => owner_a.email}})

      browser_id = get_session(started, :browser_id)
      assert is_binary(browser_id)
      assert_received {:email, _code}

      first = email_link_sign_in(recycle(started), account_a, owner_a.email)
      assert get_session(first, :browser_id) == browser_id

      second = email_link_sign_in(recycle(first), account_b, owner_b.email)
      assert get_session(second, :browser_id) == browser_id
      assert entry_accounts(second) == [account_a.id, account_b.id]

      for {account, token} <- get_session(second, :sessions) do
        assert {:ok, %UserToken{browser_digest: digest}} =
                 Auth.fetch_session_by_token(token, account)

        assert digest == Crypto.hash(browser_id)
      end

      signed_out = second |> recycle() |> delete(~p"/sign_out")
      assert get_session(signed_out, :browser_id) == nil
    end

    test "two tabs completing from one cookie: sign-out ends the session the final cookie lost",
         %{conn: conn} do
      {conn, _owner_a, account_a} = register_and_log_in(conn)
      {owner_b, account_b} = workspace_owner()
      {owner_c, account_c} = workspace_owner()

      # Both tabs start from the same cookie (the same browser id) and each
      # finishes its own sign-in; the browser keeps the cookie the last one set.
      tab_b = email_link_sign_in(conn, account_b, owner_b.email)
      tab_c = email_link_sign_in(conn, account_c, owner_c.email)
      [{_, token_b}] = Enum.filter(get_session(tab_b, :sessions), &(elem(&1, 0) == account_b.id))

      assert entry_accounts(tab_c) == [account_a.id, account_c.id]
      assert {:ok, _orphan} = Auth.fetch_session_by_token(token_b, account_b.id)

      signed_out = tab_c |> recycle() |> delete(~p"/sign_out")

      assert redirected_to(signed_out) == ~p"/"
      assert Auth.fetch_session_by_token(token_b, account_b.id) == {:error, :not_found}
      assert [_signed_out] = audit_rows(account_b, "user.signed_out")
      assert [_signed_out] = audit_rows(account_c, "user.signed_out")
      assert [_signed_out] = audit_rows(account_a, "user.signed_out")
    end
  end

  describe "a connected LiveView (review revision 7)" do
    setup %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      token = session_token(conn, account)
      %{conn: conn, owner: owner, account: account, token: token, row: session_row(token)}
    end

    test "leaves when its session expires", %{conn: conn, account: account, token: token} do
      # Minted almost sixty days ago: it expires while the page is open. The
      # margin lets the mount finish first on a loaded machine.
      minted_at =
        DateTime.utc_now() |> DateTime.add(-60, :day) |> DateTime.add(1_500, :millisecond)

      :ok = Fixtures.Auth.backdate_session_token!(token, minted_at)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}")

      {to, _flash} = assert_redirect(lv, 5_000)
      assert URI.parse(to).path == ~p"/app/#{account}"
      assert redirected_to(get(conn, ~p"/app/#{account}")) == ~p"/app/#{account}/sign_in"
    end

    test "an early expiry message only re-arms; another session's is ignored", %{
      conn: conn,
      account: account,
      row: row
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}")

      send(lv.pid, {:workspace_session_expiry, row.id})
      send(lv.pid, {:workspace_session_expiry, Ecto.UUID.generate()})

      assert render(lv) =~ account.name
      assert refute_redirected(lv) == :ok
    end

    test "leaves when its own session is revoked, but not for another session's broadcast", %{
      conn: conn,
      owner: owner,
      account: account,
      token: token
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}")

      other_token = Fixtures.Auth.create_session_token!(owner)
      other_topic = Auth.live_socket_topic(Crypto.hash(other_token))

      send(lv.pid, %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: other_topic,
        payload: %{}
      })

      assert render(lv) =~ account.name

      assert :ok = Auth.revoke_session_tokens([token], :dead_entry, %RequestContext{})

      {to, _flash} = assert_redirect(lv, 1_000)
      assert URI.parse(to).path == ~p"/app/#{account}"
    end
  end
end
