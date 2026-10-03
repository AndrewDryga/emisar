defmodule EmisarWeb.UserSessionControllerTest do
  @moduledoc """
  The emailed-code flows (plan §3 "Sign-in", "Sign-up", "Invitations" and the
  §3.1 "Email code" rows): every start sends one split code — the nonce in this
  browser's signed cookie, the code in the inbox — and only this browser can
  finish it. The code goes only to a verified, active Member of the workspace
  the URL names; anything else gets the same page and a decoy. One budget per
  address covers every flow in every workspace.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Auth, Repo}
  alias Emisar.Accounts.Membership
  alias Emisar.Audit.Event
  alias Emisar.Auth.UserToken
  alias EmisarWeb.{BillingIntent, MagicLinkHandoff, MfaChallengeHandoff}

  @code_link ~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})"
  @magic_session_keys ~w(magic_link_token_id magic_link_nonce magic_link_email
                         magic_link_expires_at magic_link_back_to browser_id)

  defp start_sign_in(conn, account, email, extra \\ %{}) do
    post(conn, ~p"/app/#{account}/sign_in/email", Map.put(extra, "user", %{"email" => email}))
  end

  # The emailed code's token id and code, taken from the test mailbox.
  defp code_from_mailbox do
    assert_received {:email, %{text_body: body}}
    [_, token_id, code] = Regex.run(@code_link, body)
    {token_id, code}
  end

  defp confirm_link(started) do
    {token_id, code} = code_from_mailbox()
    started |> recycle() |> get(~p"/sign_in/magic/#{token_id}/#{code}")
  end

  # The typed-code path: `MagicLinkLive` verifies the code with the browser's
  # nonce and hands the controller a signed `{membership_id, token_id}`.
  defp typed_code_handoff(started) do
    {token_id, code} = code_from_mailbox()
    nonce = get_session(started, :magic_link_nonce)
    {:ok, membership_id} = Auth.verify_magic_link(token_id, code, nonce, %Emisar.RequestContext{})
    {token_id, MagicLinkHandoff.sign(membership_id, token_id)}
  end

  defp member(attrs \\ %{}) do
    account = Fixtures.Accounts.create_account()

    member =
      Fixtures.Memberships.create_membership(
        Map.merge(%{account_id: account.id, role: "admin"}, Map.new(attrs))
      )

    {member, account}
  end

  defp entry(conn, account), do: List.keyfind(get_session(conn, :sessions) || [], account.id, 0)

  defp audit_rows(account, event_type) do
    Event.Query.all()
    |> Event.Query.by_account_id(account.id)
    |> Event.Query.by_event_type(event_type)
    |> Repo.all()
  end

  defp token_row(token_id), do: UserToken.Query.by_id(token_id) |> Repo.one()

  defp session_shape(conn) do
    cookie = conn.resp_cookies["emisar_magic"]

    %{
      redirect: redirected_to(conn),
      keys: Enum.filter(@magic_session_keys, &(get_session(conn, &1) != nil)),
      cookie: Map.take(cookie, [:max_age, :http_only, :same_site, :sign])
    }
  end

  describe "POST /app/:workspace/sign_in/email" do
    test "sends a code to a verified Member of the workspace and lands on the sent page", %{
      conn: conn
    } do
      {member, account} = member()

      conn = start_sign_in(conn, account, member.email)

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
      assert conn.resp_cookies["emisar_magic"].max_age == 900
      assert get_session(conn, :magic_link_email) == member.email
      assert get_session(conn, :magic_link_back_to) == ~p"/app/#{account}/sign_in"
      assert is_binary(get_session(conn, :browser_id))

      assert_received {:email, sent}
      assert [{_name, address}] = sent.to
      assert address == member.email
      [_, token_id, _code] = Regex.run(@code_link, sent.text_body)
      assert get_session(conn, :magic_link_token_id) == token_id
      assert %UserToken{membership_id: membership_id} = token_row(token_id)
      assert membership_id == member.id
    end

    test "the split-factor cookie follows the runtime secure-cookie setting", %{conn: conn} do
      {member, account} = member()
      Emisar.Config.put_override(:emisar_web, :force_secure_cookies, true)

      secure = start_sign_in(conn, account, member.email)
      assert secure.resp_cookies["emisar_magic"].secure
      assert_received {:email, _code}

      Emisar.Config.put_override(:emisar_web, :force_secure_cookies, false)

      local = start_sign_in(build_conn(), account, member.email)
      refute local.resp_cookies["emisar_magic"].secure
      assert_received {:email, _code}
    end

    test "unknown, unproved, suspended, removed, pending and other-workspace addresses get the same page and a decoy",
         %{conn: conn} do
      {member, account} = member()
      real = start_sign_in(conn, account, member.email)
      assert_received {:email, _code}

      {_other_member, other_account} = member(email: "elsewhere@example.test")

      refused_addresses = [
        "nobody-#{System.unique_integer([:positive])}@example.test",
        Fixtures.Memberships.create_membership(account_id: account.id, email_verified?: false).email,
        account.id
        |> then(&Fixtures.Memberships.create_membership(account_id: &1))
        |> Fixtures.Memberships.suspend_membership()
        |> Map.fetch!(:email),
        account.id
        |> then(&Fixtures.Memberships.create_membership(account_id: &1))
        |> Fixtures.Memberships.mark_membership_as_deleted()
        |> Map.fetch!(:email),
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          invitation_token_digest:
            Emisar.Crypto.user_invite_token_digest("invitation-#{System.unique_integer()}")
        ).email,
        # A Member of another workspace is nobody here.
        "elsewhere@example.test"
      ]

      for address <- refused_addresses do
        refused = start_sign_in(build_conn(), account, address)

        refute_received {:email, _code}, "#{address} was sent a code"
        assert session_shape(refused) == session_shape(real)
        assert get_session(refused, :magic_link_email) == address
        assert token_row(get_session(refused, :magic_link_token_id)) == nil
      end

      assert other_account.id != account.id
    end

    test "a disabled workspace issues nothing and still looks like a send", %{conn: conn} do
      {member, account} = member()
      Fixtures.Accounts.disable_account(account)

      conn = start_sign_in(conn, account, member.email)

      assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
      assert conn.resp_cookies["emisar_magic"].max_age == 900
      assert token_row(get_session(conn, :magic_link_token_id)) == nil
      refute_received {:email, _code}
    end

    test "an unknown workspace 404s", %{conn: conn} do
      assert_error_sent 404, fn ->
        post(conn, ~p"/app/no-such-workspace/sign_in/email", %{"user" => %{"email" => "a@b.co"}})
      end
    end

    test "malformed and over-long address fields get the same neutral sent page", %{conn: conn} do
      {_member, account} = member()
      long = String.duplicate("a", 400) <> "@example.test"

      for params <- [%{}, %{"user" => "not-a-map"}, %{"user" => %{"email" => ["a"]}}] do
        conn = post(conn, ~p"/app/#{account}/sign_in/email", params)
        assert redirected_to(conn) == ~p"/sign_in/magic?sent=1"
        assert conn.resp_cookies["emisar_magic"]
      end

      long_conn = start_sign_in(conn, account, long)
      assert redirected_to(long_conn) == ~p"/sign_in/magic?sent=1"
      # Too long to be anyone's address, and too long to keep in the cookie.
      assert get_session(long_conn, :magic_link_email) == ""
      refute_received {:email, _code}
    end
  end

  describe "completing an emailed code" do
    setup do
      {member, account} = member()
      %{member: member, account: account}
    end

    test "the emailed link signs in from the requesting browser and audits once", %{
      conn: conn,
      member: member,
      account: account
    } do
      completed = conn |> start_sign_in(account, member.email) |> confirm_link()

      assert redirected_to(completed) == ~p"/app/#{account}"
      assert {_account_id, token} = entry(completed, account)

      assert {:ok, %UserToken{membership_id: membership_id}} =
               Auth.fetch_session_by_token(token, account.id)

      assert membership_id == member.id
      refute get_session(completed, :magic_link_token_id)
      refute (Phoenix.Flash.get(completed.assigns.flash, :info) || "") =~ "Welcome to emisar"

      assert [%Event{actor_id: actor_id, payload: %{"method" => "magic_link"}}] =
               audit_rows(account, "user.signed_in")

      assert actor_id == member.id
    end

    test "the link without the requesting browser's cookie can't sign in", %{
      member: member,
      account: account
    } do
      _started = start_sign_in(build_conn(), account, member.email)
      {token_id, code} = code_from_mailbox()

      refused = get(build_conn(), ~p"/sign_in/magic/#{token_id}/#{code}")

      assert redirected_to(refused) == ~p"/sign_in/magic?sent=1"
      refute get_session(refused, :sessions)
    end

    test "the link for another code than the browser's can't sign in", %{
      conn: conn,
      member: member,
      account: account
    } do
      {other, _other_account} = member()
      other_started = start_sign_in(build_conn(), account, other.email)
      refute_received {:email, _decoy}
      assert other_started.resp_cookies["emisar_magic"]

      started = start_sign_in(conn, account, member.email)
      {token_id, code} = code_from_mailbox()

      # The browser holds the decoy's cookie, not this code's.
      refused =
        other_started |> recycle() |> get(~p"/sign_in/magic/#{token_id}/#{code}")

      assert redirected_to(refused) == ~p"/sign_in/magic?sent=1"
      refute get_session(refused, :sessions)
      assert token_row(token_id)
      assert started
    end

    test "a wrong code is uniformly invalid", %{conn: conn, member: member, account: account} do
      started = start_sign_in(conn, account, member.email)
      {token_id, _code} = code_from_mailbox()

      refused = started |> recycle() |> get(~p"/sign_in/magic/#{token_id}/AAAAAA")

      assert redirected_to(refused) == ~p"/sign_in/magic?sent=1"
      assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "can't be used in this browser"
      refute get_session(refused, :sessions)
    end

    test "a typed-code handoff completes only with the requesting browser's cookie", %{
      conn: conn,
      member: member,
      account: account
    } do
      started = start_sign_in(conn, account, member.email)
      {_token_id, handoff} = typed_code_handoff(started)

      stolen = get(build_conn(), ~p"/sign_in/magic/complete?#{[handoff: handoff]}")
      assert redirected_to(stolen) == ~p"/sign_in/magic?sent=1"
      refute get_session(stolen, :sessions)

      completed = started |> recycle() |> get(~p"/sign_in/magic/complete?#{[handoff: handoff]}")
      assert redirected_to(completed) == ~p"/app/#{account}"
      assert entry(completed, account)
    end

    test "a typed-code handoff lives 30 seconds", %{
      conn: conn,
      member: member,
      account: account
    } do
      started = start_sign_in(conn, account, member.email)
      {token_id, _handoff} = typed_code_handoff(started)

      stale =
        Phoenix.Token.sign(EmisarWeb.Endpoint, "magic_link signin handoff", {member.id, token_id},
          signed_at: System.system_time(:second) - 31
        )

      refused = started |> recycle() |> get(~p"/sign_in/magic/complete?#{[handoff: stale]}")

      assert redirected_to(refused) == ~p"/sign_in/magic?sent=1"
      refute get_session(refused, :sessions)
    end

    test "a handoff for another code, or a forged one, is refused", %{
      conn: conn,
      member: member,
      account: account
    } do
      started = start_sign_in(conn, account, member.email)
      _code = code_from_mailbox()
      browser = recycle(started)

      for handoff <- [
            MagicLinkHandoff.sign(member.id, Ecto.UUID.generate()),
            "not-a-real-handoff"
          ] do
        refused = get(browser, ~p"/sign_in/magic/complete?#{[handoff: handoff]}")
        assert redirected_to(refused) == ~p"/sign_in/magic?sent=1"
        refute get_session(refused, :sessions)
      end
    end

    test "a Member removed after the code was sent cannot sign in", %{
      conn: conn,
      member: member,
      account: account
    } do
      started = start_sign_in(conn, account, member.email)
      Fixtures.Memberships.mark_membership_as_deleted(member)

      refused = confirm_link(started)

      refute get_session(refused, :sessions)
      assert redirected_to(refused) == ~p"/sign_in/magic?sent=1"
    end

    test "a workspace disabled after the code was sent mints nothing", %{
      conn: conn,
      member: member,
      account: account
    } do
      started = start_sign_in(conn, account, member.email)
      Fixtures.Accounts.disable_account(account)

      refused = confirm_link(started)

      refute get_session(refused, :sessions)
      assert redirected_to(refused) == ~p"/app/#{account}/sign_in"
    end

    test "a Team choice survives the sign-in renewal; an abandoned one does not", %{
      conn: conn,
      member: member,
      account: account
    } do
      intent = BillingIntent.sign("team", :year)

      chosen =
        conn
        |> start_sign_in(account, member.email, %{"billing_intent" => intent})
        |> confirm_link()

      assert redirected_to(chosen) == ~p"/app/billing/start"
      assert get_session(chosen, :billing_intent) == intent

      abandoned =
        build_conn()
        |> init_test_session(%{billing_intent: intent})
        |> start_sign_in(account, member.email)
        |> confirm_link()

      assert redirected_to(abandoned) == ~p"/app/#{account}"
      refute get_session(abandoned, :billing_intent)
    end

    test "returns to this workspace's page or a page naming no workspace, never another workspace's",
         %{conn: conn, member: member, account: account} do
      {_other_member, other} = member()

      for {path, expected} <- [
            {~p"/app/#{account}/runs?source=operator", ~p"/app/#{account}/runs?source=operator"},
            {~p"/app/#{account.id}/approvals", ~p"/app/#{account.id}/approvals"},
            {~p"/activate?code=ABCD-EFGH", ~p"/activate?code=ABCD-EFGH"},
            {~p"/app/#{other}/runs", ~p"/app/#{account}"}
          ] do
        completed =
          conn
          |> init_test_session(%{user_return_to: path})
          |> start_sign_in(account, member.email)
          |> confirm_link()

        assert redirected_to(completed) == expected
        refute get_session(completed, :user_return_to)
      end
    end

    test "an external address is never the landing, stored or passed as a parameter", %{
      conn: conn,
      member: member,
      account: account
    } do
      forged = "https://evil.test/phish"

      for stored <- ["//evil.test/phish", forged, "/\\evil.test/phish"] do
        started =
          conn
          |> init_test_session(%{user_return_to: stored})
          |> start_sign_in(account, member.email, %{"return_to" => forged})

        {token_id, code} = code_from_mailbox()

        completed =
          started
          |> recycle()
          |> get(~p"/sign_in/magic/#{token_id}/#{code}?#{[return_to: forged]}")

        assert redirected_to(completed) == ~p"/app/#{account}"
      end
    end
  end

  describe "an invitation's code" do
    setup do
      {owner, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "team"})
      email = "invitee-#{System.unique_integer([:positive])}@example.test"

      {:ok, %{invitation_token: token, membership: invitation}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: email, role: "operator"),
          subject
        )

      %{owner: owner, account: account, token: token, invitation: invitation, email: email}
    end

    test "goes only to the invited address and accepts the invitation in this browser", %{
      conn: conn,
      account: account,
      token: token,
      invitation: invitation,
      email: email
    } do
      started =
        post(conn, ~p"/accept_invitation/#{token}", %{
          "member" => %{"display_name" => "Ines Invitee", "email" => "attacker@example.test"}
        })

      assert redirected_to(started) == ~p"/sign_in/magic?sent=1"
      assert get_session(started, :magic_link_back_to) == ~p"/accept_invitation/#{token}"
      assert_received {:email, %{to: [{_name, ^email}]} = sent}
      send(self(), {:email, sent})

      completed = confirm_link(started)

      assert redirected_to(completed) == ~p"/app/#{account}"
      assert {_account_id, _token} = entry(completed, account)
      accepted = Repo.reload!(invitation)
      assert accepted.display_name == "Ines Invitee"
      assert %DateTime{} = accepted.email_verified_at
      assert %DateTime{} = accepted.invitation_accepted_at
    end

    test "an unavailable invitation sends nothing", %{conn: conn} do
      refused =
        post(conn, ~p"/accept_invitation/not-a-token", %{"member" => %{"display_name" => "X"}})

      assert redirected_to(refused) == ~p"/accept_invitation/not-a-token"
      refute_received {:email, _code}
    end
  end

  describe "POST /sign_up" do
    defp sign_up(conn, extra \\ %{}) do
      email = "founder-#{System.unique_integer([:positive])}@example.test"
      name = "Founder Co #{System.unique_integer([:positive])}"

      params =
        Map.merge(
          %{
            "sign_up" => %{
              "email" => email,
              "full_name" => "Fran Founder",
              "account_name" => name
            }
          },
          extra
        )

      {post(conn, ~p"/sign_up", params), email, name}
    end

    test "the code creates the workspace and its owner, then welcomes them", %{conn: conn} do
      {started, email, name} = sign_up(conn)

      assert redirected_to(started) == ~p"/sign_in/magic?sent=1"
      assert get_session(started, :magic_link_back_to) == ~p"/sign_up"
      # Nothing exists before the inbox is proved.
      assert Membership.Query.all() |> Membership.Query.by_email(email) |> Repo.all() == []

      completed = confirm_link(started)

      assert Phoenix.Flash.get(completed.assigns.flash, :info) =~ "Welcome to emisar"
      [{account_id, token}] = get_session(completed, :sessions)

      assert {:ok, %UserToken{membership: %Membership{} = owner}} =
               Auth.fetch_session_by_token(token, account_id)

      assert owner.email == email
      assert owner.role == :owner
      assert owner.display_name == "Fran Founder"
      assert %DateTime{} = owner.email_verified_at
      assert owner.account.name == name
      assert redirected_to(completed) == ~p"/app/#{owner.account}"
    end

    test "a Team choice survives the sign-up and its session renewal", %{conn: conn} do
      intent = BillingIntent.sign("team", :year)
      {started, _email, _name} = sign_up(conn, %{"billing_intent" => intent})

      completed = confirm_link(started)

      assert redirected_to(completed) == ~p"/app/billing/start"
      assert get_session(completed, :billing_intent) == intent
      assert [_entry] = get_session(completed, :sessions)
    end

    test "an invalid submission returns to the form and sends nothing", %{conn: conn} do
      refused =
        post(conn, ~p"/sign_up", %{
          "sign_up" => %{"email" => "not-an-email", "account_name" => ""}
        })

      assert redirected_to(refused) == ~p"/sign_up"
      assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "Check your details"
      refute_received {:email, _code}
    end
  end

  describe "POST /sign_in/magic/resend" do
    test "re-issues the code this browser holds, for the same Member", %{conn: conn} do
      {member, account} = member()
      started = start_sign_in(conn, account, member.email)
      {first_id, _first_code} = code_from_mailbox()

      resent = started |> recycle() |> post(~p"/sign_in/magic/resend")

      assert redirected_to(resent) == ~p"/sign_in/magic?sent=1"
      {token_id, code} = code_from_mailbox()
      assert token_id != first_id
      assert get_session(resent, :magic_link_token_id) == token_id

      completed = resent |> recycle() |> get(~p"/sign_in/magic/#{token_id}/#{code}")
      assert redirected_to(completed) == ~p"/app/#{account}"
    end

    test "a decoy gets a decoy again behind the same page", %{conn: conn} do
      {_member, account} = member()
      started = start_sign_in(conn, account, "nobody-#{System.unique_integer()}@example.test")

      resent = started |> recycle() |> post(~p"/sign_in/magic/resend")

      assert redirected_to(resent) == ~p"/sign_in/magic?sent=1"
      refute_received {:email, _code}
      assert token_row(get_session(resent, :magic_link_token_id)) == nil
    end

    test "with no code in this browser there is nothing to resend", %{conn: conn} do
      assert redirected_to(post(conn, ~p"/sign_in/magic/resend")) == ~p"/sign_in"
      refute_received {:email, _code}
    end
  end

  describe "the shared address budget (review revision 10)" do
    setup %{conn: conn} do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      # A client address of its own, so this test's per-IP windows are its own.
      n = System.unique_integer([:positive])
      ip = "198.18.#{rem(div(n, 256), 256)}.#{rem(n, 256)}"
      %{conn: put_req_header(conn, "x-forwarded-for", "#{ip}, 8.233.97.247"), ip: ip}
    end

    defp from_ip(conn, ip), do: put_req_header(conn, "x-forwarded-for", "#{ip}, 8.233.97.247")

    test "five codes per address in fifteen minutes, across workspaces and flows", %{
      conn: conn,
      ip: ip
    } do
      email = "busy-#{System.unique_integer([:positive])}@example.test"
      {_one, account_one} = member(email: email)
      {_two, account_two} = member(email: email)
      {_owner, _account, owner_subject} = Fixtures.Subjects.owner_subject()

      {:ok, %{invitation_token: invitation}} =
        Accounts.invite_user_to_account(
          Fixtures.Accounts.invitation_attrs(email: email),
          owner_subject
        )

      first = start_sign_in(conn, account_one, email)
      _second = start_sign_in(from_ip(build_conn(), ip), account_two, email)

      _invited =
        post(from_ip(build_conn(), ip), ~p"/accept_invitation/#{invitation}", %{
          "member" => %{"display_name" => "Busy"}
        })

      _resent = first |> recycle() |> from_ip(ip) |> post(~p"/sign_in/magic/resend")

      _signed_up =
        post(from_ip(build_conn(), ip), ~p"/sign_up", %{
          "sign_up" => %{"email" => email, "account_name" => "Busy Co #{System.unique_integer()}"}
        })

      for _sent <- 1..5, do: assert_received({:email, _code})

      # The sixth, by any flow in any workspace, is refused without mail.
      sign_in = start_sign_in(from_ip(build_conn(), ip), account_one, email)
      assert redirected_to(sign_in) == ~p"/sign_in/magic?sent=1"
      assert Phoenix.Flash.get(sign_in.assigns.flash, :error) =~ "several sign-in emails"

      invitation_refused =
        post(from_ip(build_conn(), ip), ~p"/accept_invitation/#{invitation}", %{
          "member" => %{"display_name" => "Busy"}
        })

      assert redirected_to(invitation_refused) == ~p"/accept_invitation/#{invitation}"

      sign_up_refused =
        post(from_ip(build_conn(), ip), ~p"/sign_up", %{
          "sign_up" => %{"email" => email, "account_name" => "Busy Co #{System.unique_integer()}"}
        })

      assert redirected_to(sign_up_refused) == ~p"/sign_up"

      resend_refused = first |> recycle() |> from_ip(ip) |> post(~p"/sign_in/magic/resend")
      assert Phoenix.Flash.get(resend_refused.assigns.flash, :error) =~ "several sign-in emails"

      refute_received {:email, _code}

      # The address is normalized: case does not open a second budget.
      upper = start_sign_in(from_ip(build_conn(), ip), account_one, String.upcase(email))
      assert Phoenix.Flash.get(upper.assigns.flash, :error) =~ "several sign-in emails"
      refute_received {:email, _code}
    end

    test "a refused start keeps the browser's live code instead of a decoy", %{conn: conn, ip: ip} do
      {member, account} = member()

      {browser, live_id} =
        Enum.reduce(1..5, {conn, nil}, fn _n, {browser, _id} ->
          started = start_sign_in(browser, account, member.email)
          assert_received {:email, _code}
          {started |> recycle() |> from_ip(ip), get_session(started, :magic_link_token_id)}
        end)

      throttled = start_sign_in(browser, account, member.email)

      refute_received {:email, _code}
      assert get_session(throttled, :magic_link_token_id) == live_id
      assert token_row(live_id)
    end

    test "every start shares a per-IP cap of 30 a minute", %{conn: conn, ip: ip} do
      {_member, account} = member()

      for n <- 1..30 do
        started = start_sign_in(from_ip(conn, ip), account, "nobody-#{n}-#{ip}@example.test")
        assert redirected_to(started) == ~p"/sign_in/magic?sent=1"
      end

      limited = start_sign_in(from_ip(build_conn(), ip), account, "one-more@example.test")
      assert limited.status == 429
      refute_received {:email, _code}
    end

    test "sign-up keeps its own hourly cap per source address", %{conn: conn, ip: ip} do
      for n <- 1..20 do
        started =
          post(from_ip(conn, ip), ~p"/sign_up", %{
            "sign_up" => %{
              "email" => "cap-#{n}-#{System.unique_integer([:positive])}@example.test",
              "account_name" => "Cap Co #{n}"
            }
          })

        assert redirected_to(started) == ~p"/sign_in/magic?sent=1"
        assert_received {:email, _code}
      end

      refused =
        post(from_ip(build_conn(), ip), ~p"/sign_up", %{
          "sign_up" => %{"email" => "cap-last@example.test", "account_name" => "Cap Co last"}
        })

      assert redirected_to(refused) == ~p"/sign_up"
      assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "Too many signup attempts"
      refute_received {:email, _code}
    end
  end

  describe "the MFA sign-in challenge" do
    defp enrolled_member do
      {_owner, account, subject} = Fixtures.Subjects.owner_subject()
      secret = Auth.generate_mfa_secret()
      {owner, codes} = Fixtures.Memberships.enable_mfa!(secret, subject)
      %{member: owner, account: account, secret: secret, codes: codes, subject: subject}
    end

    defp verified_handoff(member, secret) do
      {:ok, proof} =
        Auth.verify_mfa_challenge(member.id, {:totp, Fixtures.Auth.totp_code(secret)})

      MfaChallengeHandoff.sign(proof)
    end

    # Factor one passed for `member`; the browser holds the partial-auth marker.
    defp pending_challenge(conn, %{member: member, account: account}) do
      challenged = conn |> start_sign_in(account, member.email) |> confirm_link()
      assert redirected_to(challenged) == ~p"/sign_in/mfa"
      challenged
    end

    test "an enrolled Member lands on the challenge, not a session, by link or typed code", %{
      conn: conn
    } do
      %{member: member, account: account} = enrolled = enrolled_member()

      challenged = pending_challenge(conn, enrolled)
      refute get_session(challenged, :sessions)
      assert get_session(challenged, :mfa_pending_membership_id) == member.id

      started = start_sign_in(build_conn(), account, member.email)
      {_token_id, handoff} = typed_code_handoff(started)
      typed = started |> recycle() |> get(~p"/sign_in/magic/complete?#{[handoff: handoff]}")

      assert redirected_to(typed) == ~p"/sign_in/mfa"
      refute get_session(typed, :sessions)
    end

    test "a Member without MFA signs straight in", %{conn: conn} do
      {member, account} = member()
      completed = conn |> start_sign_in(account, member.email) |> confirm_link()

      assert entry(completed, account)
      refute get_session(completed, :mfa_pending_membership_id)
    end

    test "the second factor with the matching marker signs in with MFA proved", %{conn: conn} do
      %{member: member, account: account, secret: secret} = enrolled = enrolled_member()
      challenged = pending_challenge(conn, enrolled)

      completed =
        challenged
        |> recycle()
        |> get(~p"/sign_in/mfa/complete?#{[handoff: verified_handoff(member, secret)]}")

      assert redirected_to(completed) == ~p"/app/#{account}"
      {_account_id, token} = entry(completed, account)

      assert {:ok, %UserToken{membership_id: membership_id} = session} =
               Auth.fetch_session_by_token(token, account.id)

      assert membership_id == member.id
      assert %DateTime{} = session.mfa_verified_at
      refute get_session(completed, :mfa_pending_membership_id)

      assert [%Event{payload: %{"method" => "magic_link"}}] =
               audit_rows(account, "user.signed_in")
    end

    test "a Team choice survives the challenge and the session renewal", %{conn: conn} do
      %{member: member, secret: secret} = enrolled = enrolled_member()
      intent = BillingIntent.sign("team", :year)

      # The sign-in form carries the signed plan choice; the challenge keeps it.
      challenged =
        conn
        |> start_sign_in(enrolled.account, member.email, %{"billing_intent" => intent})
        |> confirm_link()

      assert redirected_to(challenged) == ~p"/sign_in/mfa"

      completed =
        challenged
        |> recycle()
        |> get(~p"/sign_in/mfa/complete?#{[handoff: verified_handoff(member, secret)]}")

      assert redirected_to(completed) == ~p"/app/billing/start"
      assert get_session(completed, :billing_intent) == intent
    end

    test "a stale half-authentication cannot be completed later", %{conn: conn} do
      %{member: member, secret: secret} = enrolled = enrolled_member()
      challenged = pending_challenge(conn, enrolled)

      stale =
        challenged
        |> recycle()
        |> init_test_session(%{mfa_pending_at: System.system_time(:second) - 3_600})
        |> get(~p"/sign_in/mfa/complete?#{[handoff: verified_handoff(member, secret)]}")

      assert redirected_to(stale) == ~p"/sign_in"
      refute get_session(stale, :sessions)
      refute get_session(stale, :mfa_pending_membership_id)
    end

    test "completion rechecks a workspace disabled during the challenge", %{conn: conn} do
      %{member: member, account: account, secret: secret} = enrolled = enrolled_member()
      challenged = pending_challenge(conn, enrolled)
      Fixtures.Accounts.disable_account(account)

      refused =
        challenged
        |> recycle()
        |> get(~p"/sign_in/mfa/complete?#{[handoff: verified_handoff(member, secret)]}")

      refute get_session(refused, :sessions)
      assert redirected_to(refused) == ~p"/app/#{account}/sign_in"
    end

    test "a proof without the marker, or for another Member, never mints a session", %{
      conn: conn
    } do
      %{member: member, secret: secret} = enrolled = enrolled_member()
      %{member: other, secret: other_secret} = enrolled_member()

      bare = get(conn, ~p"/sign_in/mfa/complete?#{[handoff: verified_handoff(member, secret)]}")
      assert redirected_to(bare) == ~p"/sign_in"
      refute get_session(bare, :sessions)

      challenged = pending_challenge(build_conn(), enrolled)

      crossed =
        challenged
        |> recycle()
        |> get(~p"/sign_in/mfa/complete?#{[handoff: verified_handoff(other, other_secret)]}")

      assert redirected_to(crossed) == ~p"/sign_in"
      refute get_session(crossed, :sessions)
    end

    test "a proof taken before the enrollment changed is refused", %{conn: conn} do
      %{member: member, secret: secret, codes: [code | _], subject: subject} =
        enrolled = enrolled_member()

      challenged = pending_challenge(conn, enrolled)
      handoff = verified_handoff(member, secret)
      assert {:ok, _member} = Auth.disable_mfa(code, subject)

      refused = challenged |> recycle() |> get(~p"/sign_in/mfa/complete?#{[handoff: handoff]}")

      assert redirected_to(refused) == ~p"/sign_in"
      refute get_session(refused, :sessions)
    end

    test "a forged handoff, or one carrying only a Member id, is refused", %{conn: conn} do
      %{member: member} = enrolled = enrolled_member()
      challenged = pending_challenge(conn, enrolled)

      for handoff <- ["not-a-real-token", MfaChallengeHandoff.sign(member.id)] do
        refused = challenged |> recycle() |> get(~p"/sign_in/mfa/complete?#{[handoff: handoff]}")
        assert redirected_to(refused) == ~p"/sign_in"
        refute get_session(refused, :sessions)
      end
    end

    test "the partial-auth marker opens no workspace page", %{conn: conn} do
      %{account: account} = enrolled = enrolled_member()
      challenged = pending_challenge(conn, enrolled)

      refused = challenged |> recycle() |> get(~p"/app/#{account}")
      assert redirected_to(refused) == ~p"/app/#{account}/sign_in"
    end
  end

  describe "DELETE /sign_out" do
    test "ends the session, clears the cookie, and the token is dead server-side", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)
      token = session_token(conn, account)

      signed_out = delete(conn, ~p"/sign_out")

      assert redirected_to(signed_out) == ~p"/"
      assert Phoenix.Flash.get(signed_out.assigns.flash, :info) == "Signed out."
      refute get_session(signed_out, :sessions)
      assert Auth.fetch_session_by_token(token, account.id) == {:error, :not_found}
    end

    test "is a harmless redirect when no one is signed in", %{conn: conn} do
      assert redirected_to(delete(conn, ~p"/sign_out")) == ~p"/"
    end

    test "is CSRF-protected: a forced cross-site sign-out is refused", %{conn: conn} do
      {conn, _owner, account} = register_and_log_in(conn)
      token = session_token(conn, account)
      conn = Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

      assert_error_sent(403, fn -> delete(conn, ~p"/sign_out") end)
      assert {:ok, _live} = Auth.fetch_session_by_token(token, account.id)
    end
  end
end
