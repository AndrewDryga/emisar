defmodule EmisarWeb.RoleChangeSessionRefreshTest do
  @moduledoc """
  MAJOR-1: a mounted LiveView snapshots its `%Subject{}` at mount, so a role
  REDUCTION must force the member's open sockets to disconnect + remount with the
  new (reduced) permissions — otherwise a demoted operator/admin keeps stale
  powers until they navigate. An elevation or no-op keeps the sockets.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.{Accounts, Auth, Fixtures}

  setup do
    account = Fixtures.account_fixture()
    owner = Fixtures.user_fixture()
    _ = Fixtures.membership_fixture(account_id: account.id, user_id: owner.id, role: "owner")
    owner_subject = Fixtures.subject_for(owner, account, role: :owner)

    member = Fixtures.user_fixture()

    membership =
      Fixtures.membership_fixture(account_id: account.id, user_id: member.id, role: "operator")

    # A live session for the member → the socket topic a disconnect targets.
    token = Auth.create_session_token!(member, :password, false)
    topic = Auth.live_socket_topic_for_session(token)
    EmisarWeb.Endpoint.subscribe(topic)

    %{owner_subject: owner_subject, membership: membership, topic: topic}
  end

  test "a demotion disconnects the member's live sockets", %{
    owner_subject: owner_subject,
    membership: membership,
    topic: topic
  } do
    # operator → viewer drops dispatch_run — a privilege reduction.
    assert {:ok, _} = Accounts.update_membership_role(membership, :viewer, owner_subject)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500
  end

  test "a promotion does NOT disconnect (gaining permissions is safe until remount)", %{
    owner_subject: owner_subject,
    membership: membership,
    topic: topic
  } do
    # operator → admin: operator's perms are a subset of admin's, so no stale
    # power is held and no forced reconnect is warranted.
    assert {:ok, _} = Accounts.update_membership_role(membership, :admin, owner_subject)
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 200
  end

  # The SCIM directory-sync path (`Accounts.sync_set_membership_role/3`) shares
  # the same `on_membership_role_changed/2` after-commit, so the
  # permission-reduction disconnect rule above covers it too.
end
