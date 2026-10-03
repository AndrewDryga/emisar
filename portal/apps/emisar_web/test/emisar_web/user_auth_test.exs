defmodule EmisarWeb.UserAuthTest do
  @moduledoc """
  `EmisarWeb.UserAuth`'s own contracts: the cookie's `"sessions"` entries, the
  login captures, the slugless helpers and the bundle hook. The multi-workspace
  cookie behaviour end to end is `EmisarWeb.WorkspaceSessionsTest`.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Auth
  alias EmisarWeb.UserAuth

  # A conn that went through the `:browser` pipeline: session, flash and the
  # request facts a login capture reads.
  defp browser_conn(conn) do
    conn
    |> Map.replace!(:secret_key_base, EmisarWeb.Endpoint.config(:secret_key_base))
    |> bypass_through(EmisarWeb.Router, [:browser])
    |> get("/")
  end

  describe "session_entries/1" do
    test "keeps well-formed entries only, the newest per workspace, at most six" do
      # Seven workspaces: the oldest one (b) no longer fits.
      [a, b | rest] = for _ <- 1..7, do: Ecto.UUID.generate()

      session = %{
        "sessions" =>
          [
            {a, "a-old"},
            {"not-a-uuid", "token"},
            {b, nil},
            :junk,
            {b, "b"},
            {a, "a-new"}
          ] ++ Enum.map(rest, &{&1, "t-#{&1}"})
      }

      entries = UserAuth.session_entries(session)

      assert length(entries) == 6
      assert List.keyfind(entries, a, 0) == {a, "a-new"}
      refute List.keyfind(entries, b, 0)
      assert Enum.map(entries, &elem(&1, 0)) == [a | rest]
    end

    test "anything but a list is no entries" do
      for value <- [nil, "string", %{}, {Ecto.UUID.generate(), "t"}] do
        assert UserAuth.session_entries(%{"sessions" => value}) == []
      end
    end
  end

  describe "the :browser pipeline" do
    test "assigns signed_in? from the cookie's entries alone", %{conn: conn} do
      refute get(conn, ~p"/").assigns.signed_in?

      {conn, _owner, _account} = register_and_log_in(conn)
      assert get(conn, ~p"/").assigns.signed_in?

      # Even a dead entry says "signed in" to marketing pages; the pages that act
      # on a session resolve it.
      dead =
        init_test_session(build_conn(), %{sessions: [{Ecto.UUID.generate(), "dead-token"}]})

      assert get(dead, ~p"/").assigns.signed_in?
    end
  end

  describe "on_mount :assign_app_bundle" do
    test "is a pure bundle flag — always {:cont} with app_js? true, no session dependence" do
      socket = %Phoenix.LiveView.Socket{}

      assert {:cont, signed_out} = UserAuth.on_mount(:assign_app_bundle, %{}, %{}, socket)
      assert signed_out.assigns.app_js? == true

      assert {:cont, with_session} =
               UserAuth.on_mount(
                 :assign_app_bundle,
                 %{},
                 %{"sessions" => [{Ecto.UUID.generate(), "anything"}]},
                 socket
               )

      assert with_session.assigns.app_js? == true
    end

    test "a workspace LiveView loads the full app.js; a marketing page only marketing.js", %{
      conn: conn
    } do
      {conn, _owner, account} = register_and_log_in(conn)

      html = conn |> get(~p"/app/#{account}") |> html_response(200)
      assert html =~ ~s|src="/assets/app.js"|
      refute html =~ ~s|src="/assets/marketing.js"|

      html = build_conn() |> get(~p"/") |> html_response(200)
      assert html =~ ~s|src="/assets/marketing.js"|
      refute html =~ ~s|src="/assets/app.js"|
    end
  end

  describe "the stored return path" do
    test "a signed-out GET stores where to return; a POST does not", %{conn: _conn} do
      get_conn = build_conn() |> init_test_session(%{}) |> get(~p"/app")
      assert redirected_to(get_conn) == ~p"/sign_in"
      assert get_session(get_conn, :user_return_to) == ~p"/app"

      post_conn = build_conn() |> init_test_session(%{}) |> post(~p"/app/billing/start", %{})
      assert redirected_to(post_conn) == ~p"/sign_in"
      refute get_session(post_conn, :user_return_to)
    end
  end

  describe "log_in_magic_link_member/4" do
    test "installs this workspace's entry and writes no auth cookie of its own", %{conn: conn} do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(owner)

      conn =
        conn
        |> browser_conn()
        |> UserAuth.log_in_magic_link_member(%{owner | account: account}, token, false)

      assert redirected_to(conn) == ~p"/app/#{account}"
      assert get_session(conn, :sessions) == [{account.id, token}]
      # Sign-in is passwordless/SSO — no "keep me signed in" cookie; besides the
      # session itself, the only cookie is the signed list of recent workspaces.
      assert Map.keys(conn.resp_cookies) -- ["_emisar_web_key", "emisar_recent_accounts"] == []
      assert Map.has_key?(conn.resp_cookies, "emisar_recent_accounts")
    end
  end

  describe "log_in_sso_member/3" do
    test "a Member removed after the callback gets a controlled denial and no session", %{
      conn: conn
    } do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      %{membership: member, identity: identity} = Fixtures.SSO.create_directory_member(provider)
      assert {:ok, _removed} = Emisar.Accounts.delete_membership(member, subject)

      assert {:error, :membership_unavailable} =
               UserAuth.log_in_sso_member(
                 browser_conn(conn),
                 %{membership: member, identity: identity, provider: provider},
                 account
               )

      assert Emisar.Auth.UserToken.Query.by_membership(account.id, member.id)
             |> Emisar.Repo.aggregate(:count) == 0
    end
  end

  describe "subject_for_account/2" do
    test "acts only through this browser's live session for an active workspace", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      {_other_owner, other, _other_subject} = Fixtures.Subjects.owner_subject()
      conn = browser_conn(conn)

      assert {:ok, subject} = UserAuth.subject_for_account(conn, account.slug)
      assert subject.membership_id == owner.id
      assert {:ok, _by_id} = UserAuth.subject_for_account(conn, account.id)

      # No entry here, an unknown ref and a malformed one look the same.
      assert UserAuth.subject_for_account(conn, other.id) == {:error, :not_found}
      assert UserAuth.subject_for_account(conn, "no-such-workspace") == {:error, :not_found}
      assert UserAuth.subject_for_account(conn, nil) == {:error, :not_found}

      Fixtures.Accounts.disable_account(account)
      assert UserAuth.subject_for_account(conn, account.id) == {:error, :not_found}
    end

    test "a token presented under another workspace is refused", %{conn: conn} do
      {owner, _account, _subject} = Fixtures.Subjects.owner_subject()
      {_other_owner, other, _other_subject} = Fixtures.Subjects.owner_subject()
      token = Fixtures.Auth.create_session_token!(owner)

      conn =
        conn
        |> init_test_session(%{sessions: [{other.id, token}]})
        |> browser_conn()

      assert UserAuth.subject_for_account(conn, other.id) == {:error, :not_found}
    end
  end

  describe "signed_in_accounts/1" do
    test "lists the live entries' workspaces by name and skips dead ones", %{conn: conn} do
      {conn, _owner_z, zulu} = register_and_log_in(conn, %{account: %{name: "Zulu Ops"}})
      {conn, _owner_a, alpha} = register_and_log_in(conn, %{account: %{name: "alpha Ops"}})
      {conn, _owner_d, dead} = register_and_log_in(conn, %{account: %{name: "Dead Ops"}})
      Fixtures.Auth.delete_session_token!(session_token(conn, dead))

      session = %{"sessions" => get_session(conn, :sessions)}

      assert UserAuth.signed_in_accounts(session) |> Enum.map(& &1.id) == [alpha.id, zulu.id]
      assert {:ok, _live} = Auth.fetch_session_by_token(session_token(conn, zulu), zulu.id)
    end
  end
end
