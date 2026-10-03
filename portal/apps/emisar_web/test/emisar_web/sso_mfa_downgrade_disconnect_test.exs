defmodule EmisarWeb.SSOMFADowngradeDisconnectTest do
  @moduledoc """
  A connection's MFA-trust downgrade ends only the sessions that connection
  vouched for, including their open LiveView sockets: the same Member's
  email-code session, and the same person's SSO session in another workspace,
  keep theirs.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Auth, Crypto, Fixtures, SSO}

  defp topic(token), do: Auth.live_socket_topic(Crypto.hash(token))

  test "true-to-false ends only the provider's sessions and disconnects their browsers" do
    {owner, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id, satisfies_mfa: true)
    identity = Fixtures.SSO.create_user_identity(provider_id: provider.id, membership: owner)

    # The same person signs in to another workspace through the same IdP.
    sibling = Fixtures.Accounts.create_account(plan: "team")

    sibling_member =
      Fixtures.Memberships.create_membership(account_id: sibling.id, email: owner.email)

    sibling_provider =
      Fixtures.SSO.create_identity_provider(
        account_id: sibling.id,
        issuer: provider.issuer,
        satisfies_mfa: true
      )

    sibling_identity =
      Fixtures.SSO.create_user_identity(
        provider_id: sibling_provider.id,
        membership: sibling_member,
        provider_identifier: identity.provider_identifier
      )

    provider_token =
      Fixtures.Auth.create_session_token!(owner, :sso, DateTime.utc_now(), %{},
        user_identity_id: identity.id
      )

    sibling_token =
      Fixtures.Auth.create_session_token!(sibling_member, :sso, DateTime.utc_now(), %{},
        user_identity_id: sibling_identity.id
      )

    magic_token = Fixtures.Auth.create_session_token!(owner)
    held = Fixtures.Subjects.subject_for(owner, session: provider_token)

    for token <- [provider_token, sibling_token, magic_token],
        do: EmisarWeb.Endpoint.subscribe(topic(token))

    provider_topic = topic(provider_token)
    sibling_topic = topic(sibling_token)
    magic_topic = topic(magic_token)

    assert {:ok, downgraded} = SSO.update_provider(provider, %{satisfies_mfa: false}, subject)

    refute downgraded.satisfies_mfa
    assert_receive %Phoenix.Socket.Broadcast{topic: ^provider_topic, event: "disconnect"}, 500
    refute_receive %Phoenix.Socket.Broadcast{topic: ^magic_topic, event: "disconnect"}, 100
    refute_receive %Phoenix.Socket.Broadcast{topic: ^sibling_topic, event: "disconnect"}, 100
    assert Auth.fetch_session_by_token(provider_token, account.id) == {:error, :not_found}
    assert Auth.fetch_current_subject([], held) == {:error, :unauthorized}
    assert {:ok, _magic} = Auth.fetch_session_by_token(magic_token, account.id)
    assert {:ok, _sibling} = Auth.fetch_session_by_token(sibling_token, sibling.id)

    # Restoring the trust revives nothing.
    assert {:ok, _restored} = SSO.update_provider(downgraded, %{satisfies_mfa: true}, subject)
    assert Auth.fetch_current_subject([], held) == {:error, :unauthorized}
  end
end
