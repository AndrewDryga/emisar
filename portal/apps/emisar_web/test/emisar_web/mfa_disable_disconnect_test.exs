defmodule EmisarWeb.MfaDisableDisconnectTest do
  @moduledoc """
  Turning your own MFA off must tear down the open LiveViews, without signing you
  out.

  Sessions deliberately survive a self-service disable, so the cookie is not what
  carries the stale decision — the mounted SOCKETS are. Each one decided its
  gates at mount and holds a `%Subject{}` whose bound `mfa` was true, so an
  already-open `/admin/live` would stay usable until its next mount and later
  audit rows would be stamped from the old claim. Dropping the sockets makes each
  reconnect, remount, and re-decide.

  This can't be proven from the `emisar` app alone: `disconnect_live_sessions/1`
  goes through `:session_disconnect_handler`, which lives in `emisar_web` and is
  a silent no-op in an `:emisar`-only test process — the same reason
  `EmisarWeb.EndAllSessionsDisconnectTest` exists.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Auth, Fixtures}

  test "disabling MFA disconnects the user's live sockets but keeps their session" do
    {user, _account, subject} = Fixtures.Subjects.owner_subject()
    {_user, [recovery_code | _]} = Fixtures.Users.enable_mfa!(Auth.generate_mfa_secret(), subject)

    token = Fixtures.Auth.create_session_token!(user, :magic_link, DateTime.utc_now())
    topic = Auth.live_socket_topic_for_session(token)
    EmisarWeb.Endpoint.subscribe(topic)

    assert {:ok, disabled} = Auth.disable_mfa(recovery_code, subject)
    refute disabled.mfa_enabled_at

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 500
    assert {:ok, _user, _session} = Auth.fetch_user_and_token_by_session_token(token)
  end
end
