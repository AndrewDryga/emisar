defmodule EmisarWeb.SSOMFADowngradeDisconnectTest do
  @moduledoc """
  A connection's MFA-trust downgrade invalidates only the credentials that
  connection vouched for, including their open LiveView sockets.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Auth, Fixtures, SSO}

  test "true-to-false deletes and disconnects the provider session only" do
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

    provider_token =
      Fixtures.Auth.create_session_token!(user, :sso, DateTime.utc_now(), %{},
        user_identity_id: identity.id
      )

    magic_token = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
    provider_topic = Auth.live_socket_topic_for_session(provider_token)
    magic_topic = Auth.live_socket_topic_for_session(magic_token)
    EmisarWeb.Endpoint.subscribe(provider_topic)
    EmisarWeb.Endpoint.subscribe(magic_topic)

    assert {:ok, downgraded} =
             SSO.update_provider(provider, %{satisfies_mfa: false}, subject)

    refute downgraded.satisfies_mfa
    assert_receive %Phoenix.Socket.Broadcast{topic: ^provider_topic, event: "disconnect"}, 500
    refute_receive %Phoenix.Socket.Broadcast{topic: ^magic_topic, event: "disconnect"}, 100
    assert Auth.fetch_user_and_token_by_session_token(provider_token) == {:error, :not_found}
    assert {:ok, ^user, _session} = Auth.fetch_user_and_token_by_session_token(magic_token)
  end
end
