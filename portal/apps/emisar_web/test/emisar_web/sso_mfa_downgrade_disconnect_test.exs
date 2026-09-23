defmodule EmisarWeb.SSOMFADowngradeDisconnectTest do
  @moduledoc """
  A connection's MFA-trust downgrade invalidates only the credentials that
  connection vouched for, including their open LiveView sockets.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, Auth, Fixtures, SSO}

  test "true-to-false retires only the provider's grants and disconnects affected browsers" do
    {user, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})

    provider =
      Fixtures.SSO.create_identity_provider(%{
        account_id: account.id,
        satisfies_mfa: true
      })

    identity =
      Fixtures.SSO.create_user_identity(%{
        account_id: account.id,
        provider_id: provider.id,
        user_id: user.id
      })

    sibling = Fixtures.Accounts.create_account(plan: "team")
    Fixtures.Memberships.create_membership(account_id: sibling.id, user_id: user.id)

    sibling_provider =
      Fixtures.SSO.create_identity_provider(account_id: sibling.id, issuer: provider.issuer)

    Fixtures.SSO.create_user_identity(
      account_id: sibling.id,
      provider_id: sibling_provider.id,
      user_id: user.id
    )

    provider_token =
      Fixtures.Auth.create_session_token!(user, :sso, DateTime.utc_now(), %{},
        user_identity_id: identity.id
      )

    magic_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
    {:ok, _user, session} = Auth.fetch_user_and_token_by_session_token(provider_token)
    held = Fixtures.Subjects.subject_for(user, account, session: session)
    provider_topic = Auth.live_socket_topic_for_session(provider_token)
    magic_topic = Auth.live_socket_topic_for_session(magic_token)
    EmisarWeb.Endpoint.subscribe(provider_topic)
    EmisarWeb.Endpoint.subscribe(magic_topic)

    assert {:ok, downgraded} =
             SSO.update_provider(provider, %{satisfies_mfa: false}, subject)

    refute downgraded.satisfies_mfa
    assert_receive %Phoenix.Socket.Broadcast{topic: ^provider_topic, event: "disconnect"}, 500
    refute_receive %Phoenix.Socket.Broadcast{topic: ^magic_topic, event: "disconnect"}, 100
    assert {:ok, _user, _session} = Auth.fetch_user_and_token_by_session_token(provider_token)
    assert Auth.fetch_current_subject([], held) == {:error, :unauthorized}

    assert Accounts.fetch_membership_by_account_id_or_slug(user, account.id, session) ==
             {:error, :not_found}

    assert {:ok, _sibling_member} =
             Accounts.fetch_membership_by_account_id_or_slug(user, sibling.id, session)

    assert {:ok, ^user, _session} = Auth.fetch_user_and_token_by_session_token(magic_token)

    assert {:ok, _restored_trust} =
             SSO.update_provider(downgraded, %{satisfies_mfa: true}, subject)

    assert Auth.fetch_current_subject([], held) == {:error, :unauthorized}
  end
end
