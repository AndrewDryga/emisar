defmodule EmisarWeb.MembershipAuthorizationSessionRefreshTest do
  @moduledoc """
  Role and directory-pending changes remount with current authority. Scope-only
  changes refresh controls without losing open forms or output.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Auth, Fixtures, SSO}
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

    # An older browser proved B before this person's A membership existed.
    # Refreshing A must not disturb that independent same-User browser.
    sibling = Fixtures.Accounts.create_account()
    Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: member.id)
    other_token = Fixtures.Auth.create_session_token!(member, :magic_link, nil)
    other_topic = Auth.live_socket_topic_for_session(other_token)
    EmisarWeb.Endpoint.subscribe(other_topic)

    membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: member.id,
        role: "operator"
      )

    token = Fixtures.Auth.create_session_token!(member, :magic_link, nil)
    topic = Auth.live_socket_topic_for_session(token)
    EmisarWeb.Endpoint.subscribe(topic)

    {:ok, session} = Auth.fetch_session_by_token(token)
    held = Fixtures.Subjects.subject_for(member, account, session: session)
    Accounts.subscribe_account_team(account.id)

    %{
      account: account,
      member: member,
      membership: membership,
      owner_subject: owner_subject,
      token: token,
      topic: topic,
      other_topic: other_topic,
      other_token: other_token,
      sibling: sibling,
      held: held
    }
  end

  describe "broadcast_disconnect_for_membership/1" do
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
      assert {:ok, %{user: %{id: member_id}}} = Auth.fetch_session_by_token(token)
      assert member_id == member.id
    end

    test "a role reduction reconnects the affected member", %{
      membership: membership,
      owner_subject: owner_subject,
      topic: topic,
      other_topic: other_topic
    } do
      assert {:ok, _membership} =
               Accounts.update_membership_role(membership, :viewer, owner_subject)

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500
      refute_receive %Phoenix.Socket.Broadcast{topic: ^other_topic, event: "disconnect"}, 100
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
      membership_id = membership.id
      {:ok, restricted} = RunnerAccess.restricted(["database"], [])

      assert {:ok, narrowed} =
               Accounts.update_membership_runner_access(
                 membership,
                 restricted,
                 owner_subject
               )

      assert_receive {:list_changed, :team, "membership.runner_access_changed", ^membership_id}
      refute_receive {:list_changed, :team, _, _}, 100
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100

      assert {:ok, _widened} =
               Accounts.update_membership_runner_access(
                 narrowed,
                 RunnerAccess.all(),
                 owner_subject
               )

      assert_receive {:list_changed, :team, "membership.runner_access_changed", ^membership_id}
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
      membership_id = membership.id

      assert {:ok, narrowed} =
               Accounts.update_membership_runner_access(
                 membership,
                 restricted,
                 owner_subject
               )

      assert_receive {:list_changed, :team, "membership.runner_access_changed", ^membership_id}
      refute_receive {:list_changed, :team, _, _}, 100
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100

      assert {:ok, _widened} =
               Accounts.update_membership_runner_access(
                 narrowed,
                 RunnerAccess.all(),
                 owner_subject
               )

      assert_receive {:list_changed, :team, "membership.runner_access_changed", ^membership_id}
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
      topic: topic,
      other_topic: other_topic
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
      refute_receive %Phoenix.Socket.Broadcast{topic: ^other_topic, event: "disconnect"}, 100
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
      topic: topic,
      other_topic: other_topic
    } do
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      membership_id = membership.id

      assert {:ok, updated} =
               Accounts.sync_set_membership_authorization(
                 membership,
                 :operator,
                 RunnerAccess.none(),
                 provider
               )

      assert_receive {:list_changed, :team, "membership.runner_access_changed", ^membership_id}
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

      assert_receive {:list_changed, :team, "membership.role_changed", ^membership_id}
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500
      refute_receive %Phoenix.Socket.Broadcast{topic: ^other_topic, event: "disconnect"}, 100
    end
  end

  for operation <- [:suspend_membership, :delete_membership] do
    @operation operation
    test "#{operation} retires A without interrupting a same-User B-only browser",
         %{membership: _, owner_subject: _} = context do
      assert {:ok, _member} =
               apply(Accounts, @operation, [context.membership, context.owner_subject])

      assert_local_retirement(context)
    end
  end

  for operation <- [:disable, :close] do
    @operation operation
    test "account #{@operation} preserves a same-User B-only browser",
         %{account: _, owner_subject: _} = context do
      result =
        case @operation do
          :disable ->
            Accounts.set_account_disabled_for_support(
              context.account.id,
              true,
              "Temporary hold",
              context.owner_subject
            )

          :close ->
            Accounts.close_account(context.account.id, "Requested closure", context.owner_subject)
        end

      assert {:ok, _account} = result
      assert_local_retirement(context)
    end
  end

  for operation <- [:patch, :repost, :delete] do
    @operation operation
    test "SCIM #{@operation} retires A without interrupting a same-User B-only browser",
         %{account: _, owner_subject: _, member: _, membership: _, topic: _} = context do
      Fixtures.Accounts.create_subscription(context.account, "enterprise")
      provider = Fixtures.SSO.create_identity_provider(account_id: context.account.id)
      {:ok, provider, _raw} = SSO.enable_scim(provider, context.owner_subject)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: context.account.id,
          provider_id: provider.id,
          user_id: context.member.id,
          scim_external_id: "directory-person",
          provisioned_via: :scim
        )

      if @operation == :delete do
        assert {:ok, _member} =
                 Accounts.sync_set_membership_authorization(
                   context.membership,
                   :admin,
                   RunnerAccess.all(),
                   provider
                 )

        topic = context.topic
        assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500
      end

      case @operation do
        :patch ->
          assert {:ok, _identity} =
                   SSO.scim_patch_user(provider, identity.id, [
                     %{"op" => "replace", "path" => "active", "value" => false}
                   ])

        :repost ->
          assert {:ok, %{identity: _identity}} =
                   SSO.scim_provision_user(provider, %{
                     external_id: "directory-person",
                     active: false
                   })

        :delete ->
          assert {:ok, _identity} = SSO.scim_delete_user(provider, identity.id)
      end

      assert_local_retirement(context)
    end
  end

  defp assert_local_retirement(context) do
    %{topic: topic, other_topic: other_topic, account: account, sibling: sibling} = context

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500
    refute_receive %Phoenix.Socket.Broadcast{topic: ^other_topic, event: "disconnect"}, 100
    assert Auth.fetch_current_subject([], context.held) == {:error, :unauthorized}

    for raw <- [context.token, context.other_token] do
      assert {:ok, session} = Auth.fetch_session_by_token(raw)

      assert {:ok, _member} =
               Accounts.fetch_membership_by_account_id_or_slug(sibling.id, session)

      assert Accounts.fetch_membership_by_account_id_or_slug(account.id, session) ==
               {:error, :not_found}
    end
  end
end
