defmodule EmisarWeb.PerSessionRevocationDisconnectTest do
  @moduledoc """
  Per-session revocation deletes one credential and tears down only the
  LiveView sockets bound to that exact token: another session of the same
  Member, and another workspace's session in the same browser, keep their
  pages. The web-side disconnect handler is exercised here; data-layer tests
  cannot observe its Phoenix broadcast.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Auth, Crypto, RequestContext}

  defp topic(token), do: Auth.live_socket_topic(Crypto.hash(token))

  defp sessions(subject, presented) do
    {:ok, sessions, _metadata} =
      Auth.list_sessions_for_member(Crypto.hash(presented), subject, page: [limit: 100])

    sessions
  end

  test "revoking A's session redirects only A's LiveView; B's LiveView in the same browser stays",
       %{conn: conn} do
    {conn, owner_a, account_a} = register_and_log_in(conn)
    {conn, _owner_b, account_b} = register_and_log_in(conn)
    token_a = session_token(conn, account_a)
    {:ok, lv_a, _html} = live(conn, ~p"/app/#{account_a}")
    {:ok, lv_b, _html} = live(conn, ~p"/app/#{account_b}")

    # The owner signs this browser's A session out from another device.
    other_device = Fixtures.Auth.create_session_token!(owner_a)
    subject = Fixtures.Subjects.subject_for(owner_a, session: other_device)
    revoked = subject |> sessions(other_device) |> Enum.find(&(not &1.current?))

    assert Auth.revoke_session(revoked.id, subject) == :ok

    {to, _flash} = assert_redirect(lv_a, 1_000)
    assert URI.parse(to).path == ~p"/app/#{account_a}"
    assert render(lv_b) =~ account_b.name
    assert Auth.fetch_session_by_token(token_a, account_a.id) == {:error, :not_found}

    assert {:ok, _live} =
             Auth.fetch_session_by_token(session_token(conn, account_b), account_b.id)
  end

  describe "the disconnect broadcast" do
    setup do
      {owner, account, subject} = Fixtures.Subjects.owner_subject()
      %{owner: owner, account: account, subject: subject}
    end

    test "a committed revocation disconnects only the selected live session", %{
      owner: owner,
      account: account,
      subject: subject
    } do
      revoked = Fixtures.Auth.create_session_token!(owner)
      survivor = Fixtures.Auth.create_session_token!(owner)
      revoked_session = subject |> sessions(revoked) |> Enum.find(& &1.current?)

      revoked_topic = topic(revoked)
      survivor_topic = topic(survivor)
      EmisarWeb.Endpoint.subscribe(revoked_topic)
      EmisarWeb.Endpoint.subscribe(survivor_topic)

      assert Auth.revoke_session(revoked_session.id, subject) == :ok

      assert_receive %Phoenix.Socket.Broadcast{topic: ^revoked_topic, event: "disconnect"}, 500
      refute_receive %Phoenix.Socket.Broadcast{topic: ^survivor_topic, event: "disconnect"}, 100
      assert Auth.fetch_session_by_token(revoked, account.id) == {:error, :not_found}
      assert {:ok, %{membership_id: owner_id}} = Auth.fetch_session_by_token(survivor, account.id)
      assert owner_id == owner.id

      assert Auth.revoke_session(revoked_session.id, subject) == {:error, :not_found}
      refute_receive %Phoenix.Socket.Broadcast{topic: ^revoked_topic, event: "disconnect"}, 100
    end

    test "another Member's session id emits no disconnect and leaves its token live", %{
      account: account,
      subject: subject
    } do
      teammate = Fixtures.Memberships.create_membership(account_id: account.id)
      teammate_token = Fixtures.Auth.create_session_token!(teammate)
      assert {:ok, teammate_session} = Auth.fetch_session_by_token(teammate_token, account.id)

      teammate_topic = topic(teammate_token)
      EmisarWeb.Endpoint.subscribe(teammate_topic)

      assert Auth.revoke_session(teammate_session.id, subject) == {:error, :not_found}
      refute_receive %Phoenix.Socket.Broadcast{topic: ^teammate_topic, event: "disconnect"}, 100
      assert {:ok, _live} = Auth.fetch_session_by_token(teammate_token, account.id)
    end

    test "a rolled-back revocation emits no disconnect and preserves the token", %{
      owner: owner,
      account: account,
      subject: subject
    } do
      token = Fixtures.Auth.create_session_token!(owner)
      subject = %{subject | context: %RequestContext{request_id: %{invalid: true}}}
      assert {:ok, session} = Auth.fetch_session_by_token(token, account.id)

      session_topic = topic(token)
      EmisarWeb.Endpoint.subscribe(session_topic)

      assert {:error, %Ecto.Changeset{}} = Auth.revoke_session(session.id, subject)
      refute_receive %Phoenix.Socket.Broadcast{topic: ^session_topic, event: "disconnect"}, 100
      assert {:ok, _live} = Auth.fetch_session_by_token(token, account.id)
    end
  end
end
