defmodule EmisarWeb.MembershipAuthorizationSessionRefreshTest do
  @moduledoc """
  Role and directory-pending changes remount with current authority. Scope-only
  changes refresh controls without losing open forms or output.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Auth, Fixtures}
  alias Emisar.Accounts.RunnerAccess

  setup do
    account = Fixtures.Accounts.create_account()
    owner = Fixtures.Users.create_user()

    _owner_membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: owner.id,
        role: "owner"
      )

    owner_subject = Fixtures.Subjects.subject_for(owner, account, role: :owner)
    member = Fixtures.Users.create_user()

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: member.id,
        role: "operator"
      )

    token = Fixtures.Auth.create_session_token!(member, :magic_link, nil)
    topic = Auth.live_socket_topic_for_session(token)
    EmisarWeb.Endpoint.subscribe(topic)

    other_member = Fixtures.Users.create_user()
    other_token = Fixtures.Auth.create_session_token!(other_member, :magic_link, nil)
    other_topic = Auth.live_socket_topic_for_session(other_token)
    EmisarWeb.Endpoint.subscribe(other_topic)
    Accounts.subscribe_account_team(account.id)

    %{
      account: account,
      member: member,
      membership: membership,
      owner_subject: owner_subject,
      token: token,
      topic: topic,
      other_topic: other_topic
    }
  end

  test "a role promotion reconnects only the affected member and preserves the session", %{
    member: member,
    membership: membership,
    owner_subject: owner_subject,
    token: token,
    topic: topic,
    other_topic: other_topic
  } do
    assert {:ok, _membership} =
             Accounts.update_membership_role(membership, :admin, owner_subject)

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500
    refute_receive %Phoenix.Socket.Broadcast{topic: ^other_topic, event: "disconnect"}, 100
    assert {:ok, %{id: member_id}, _session} = Auth.fetch_user_and_token_by_session_token(token)
    assert member_id == member.id
  end

  test "a role reduction reconnects the affected member", %{
    membership: membership,
    owner_subject: owner_subject,
    topic: topic
  } do
    assert {:ok, _membership} =
             Accounts.update_membership_role(membership, :viewer, owner_subject)

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500
  end

  test "re-applying the same role does not reconnect", %{
    membership: membership,
    owner_subject: owner_subject,
    topic: topic
  } do
    assert {:ok, _membership} =
             Accounts.update_membership_role(membership, :operator, owner_subject)

    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100
    refute_receive {:list_changed, :team, _, _}, 100
  end

  test "runner-scope narrowing and widening each notify once without reconnecting", %{
    account: account,
    membership: membership,
    owner_subject: owner_subject,
    topic: topic
  } do
    _runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
    user_id = membership.user_id
    {:ok, restricted} = RunnerAccess.restricted(["database"], [])

    assert {:ok, narrowed} =
             Accounts.update_membership_runner_access(
               membership,
               restricted,
               owner_subject
             )

    assert_receive {:list_changed, :team, "membership.runner_access_changed", ^user_id}
    refute_receive {:list_changed, :team, _, _}, 100
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100

    assert {:ok, _widened} =
             Accounts.update_membership_runner_access(
               narrowed,
               RunnerAccess.all(),
               owner_subject
             )

    assert_receive {:list_changed, :team, "membership.runner_access_changed", ^user_id}
    refute_receive {:list_changed, :team, _, _}, 100
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100
  end

  test "pack-scope narrowing and widening each notify once without reconnecting", %{
    account: account,
    membership: membership,
    owner_subject: owner_subject,
    topic: topic
  } do
    _pack =
      Fixtures.Catalog.create_trusted_pack_version(account_id: account.id, pack_id: "postgres")

    {:ok, restricted} = RunnerAccess.new(:all, [], [], :restricted, ["postgres"])
    user_id = membership.user_id

    assert {:ok, narrowed} =
             Accounts.update_membership_runner_access(
               membership,
               restricted,
               owner_subject
             )

    assert_receive {:list_changed, :team, "membership.runner_access_changed", ^user_id}
    refute_receive {:list_changed, :team, _, _}, 100
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100

    assert {:ok, _widened} =
             Accounts.update_membership_runner_access(
               narrowed,
               RunnerAccess.all(),
               owner_subject
             )

    assert_receive {:list_changed, :team, "membership.runner_access_changed", ^user_id}
    refute_receive {:list_changed, :team, _, _}, 100
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100
  end

  test "re-applying identical runner and pack access does not reconnect", %{
    membership: membership,
    owner_subject: owner_subject,
    topic: topic
  } do
    assert {:ok, _membership} =
             Accounts.update_membership_runner_access(
               membership,
               RunnerAccess.all(),
               owner_subject
             )

    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100
    refute_receive {:list_changed, :team, _, _}, 100
  end

  test "directory reconciliation reconnects once when role and scope change together", %{
    account: account,
    membership: membership,
    topic: topic
  } do
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
    {:ok, restricted} = RunnerAccess.restricted(["production"], [])

    assert {:ok, updated} =
             Accounts.sync_set_membership_authorization(
               membership,
               :admin,
               restricted,
               provider
             )

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100

    assert {:ok, _unchanged} =
             Accounts.sync_set_membership_authorization(
               updated,
               :admin,
               restricted,
               provider
             )

    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100
  end

  test "directory scope-only reconciliation keeps the session but pending recovery remounts", %{
    account: account,
    membership: membership,
    topic: topic
  } do
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
    user_id = membership.user_id

    assert {:ok, updated} =
             Accounts.sync_set_membership_authorization(
               membership,
               :operator,
               RunnerAccess.none(),
               provider
             )

    assert_receive {:list_changed, :team, "membership.runner_access_changed", ^user_id}
    refute_receive {:list_changed, :team, _, _}, 100
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100

    updated
    |> Ecto.Changeset.change(
      directory_authorization_pending_version: provider.authorization_version
    )
    |> Emisar.Repo.update!()

    assert {:ok, _updated} =
             Accounts.sync_set_membership_authorization(
               updated,
               :operator,
               RunnerAccess.none(),
               provider
             )

    assert_receive {:list_changed, :team, "membership.role_changed", ^user_id}
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500
  end
end
