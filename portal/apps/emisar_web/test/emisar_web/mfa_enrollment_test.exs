defmodule EmisarWeb.MfaEnrollmentTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Auth
  alias EmisarWeb.MfaEnrollment

  setup do
    {user, account, _owner} = Fixtures.Subjects.owner_subject()
    raw = Fixtures.Auth.create_session_token!(user, :magic_link, nil)
    {:ok, _user, auth} = Auth.fetch_user_and_token_by_session_token(raw)
    subject = Fixtures.Subjects.subject_for(user, account, session: auth)
    subject = %{subject | permissions: MapSet.new()}

    socket =
      Phoenix.Component.assign(%Phoenix.LiveView.Socket{},
        current_user: user,
        current_auth: auth,
        current_subject: subject,
        current_account: account
      )

    {:ok, enrolled, _codes} =
      Fixtures.Users.enroll_mfa(Auth.generate_mfa_secret(), subject, session_token: raw)

    %{socket: socket, raw: raw, enrolled: enrolled}
  end

  test "carries persisted proof without widening the destination's authority", %{
    socket: socket,
    raw: raw,
    enrolled: enrolled
  } do
    assert {:ok, updated} = MfaEnrollment.assign_current_proof(socket, enrolled)
    {:ok, user, auth} = Auth.fetch_user_and_token_by_session_token(raw)
    assert updated.assigns.current_auth == auth
    assert updated.assigns.current_user == user
    assert updated.assigns.current_subject.mfa_enrollment_verified_at == user.mfa_enabled_at
    assert updated.assigns.current_subject.mfa
    assert updated.assigns.current_subject.permissions == MapSet.new()

    assert updated.assigns.current_subject.member_grant_id ==
             socket.assigns.current_subject.member_grant_id

    assert updated.assigns.current_subject.user_identity_id ==
             socket.assigns.current_subject.user_identity_id

    assert updated.assigns.current_subject.auth_method ==
             socket.assigns.current_subject.auth_method
  end

  test "a post-commit revocation is refused before revealing recovery codes", %{
    socket: socket,
    raw: raw,
    enrolled: enrolled
  } do
    :ok = Auth.delete_session_token(raw)
    assert MfaEnrollment.assign_current_proof(socket, enrolled) == {:error, :session_not_found}
  end

  for transition <- [:disable, :replace] do
    @transition transition
    test "a concurrent factor #{@transition} cannot be overwritten by the enrollment response", %{
      socket: socket,
      enrolled: enrolled
    } do
      epoch =
        if @transition == :replace,
          do: DateTime.add(enrolled.mfa_enabled_at, 1, :second),
          else: nil

      Fixtures.Users.set_mfa_state(enrolled, mfa_enabled_at: epoch)
      assert MfaEnrollment.assign_current_proof(socket, enrolled) == {:error, :mfa_proof_stale}
    end
  end
end
