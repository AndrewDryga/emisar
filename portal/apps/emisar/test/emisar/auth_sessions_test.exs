defmodule Emisar.AuthSessionsTest do
  @moduledoc """
  Behavioural coverage for the session surface: the per-request predicate
  behind `fetch_session_by_token/2`, the cookie-wide reads and ends
  (`list_live_sessions/1`, `complete_browser_sign_out/3`,
  `revoke_session_tokens/3`), and the Member-facing list, revoke one and
  revoke-others-keep-current that Profile calls. How sessions are minted lives
  in AuthTest.
  """
  use Emisar.DataCase, async: true
  alias Emisar.{Accounts, Audit, Auth, Config, Crypto, Fixtures, RequestContext}
  alias Emisar.Auth.UserToken

  defmodule RecordingSessionDisconnector do
    def disconnect_live_sessions(topics) do
      send(self(), {:session_disconnect, topics, Emisar.Repo.in_transaction?()})
      :ok
    end
  end

  defp events_of(account_id, event_type) do
    Audit.Event.Query.all()
    |> Audit.Event.Query.by_account_id(account_id)
    |> Audit.Event.Query.by_event_type(event_type)
    |> Repo.all()
  end

  # A workspace with an owner Member and no session yet.
  defp owner_member do
    account = Fixtures.Accounts.create_account()
    owner = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
    {owner, account}
  end

  # One enabled connection per kind and workspace: a second route in the same
  # workspace takes `kind: :openid_connect`.
  defp sso_member(account, kind \\ :okta) do
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id, kind: kind)

    member =
      Fixtures.Memberships.create_membership(account_id: account.id, email_verified?: false)

    identity =
      Fixtures.SSO.create_user_identity(%{
        account_id: account.id,
        provider_id: provider.id,
        membership: member
      })

    raw =
      Fixtures.Auth.create_session_token!(member, :sso, nil, %{}, user_identity_id: identity.id)

    %{provider: provider, member: member, identity: identity, raw: raw}
  end

  describe "fetch_session_by_token/2" do
    test "authenticates a live session only under its own workspace, with its authority preloaded" do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()
      other = Fixtures.Accounts.create_account()
      raw = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)

      assert {:ok, %UserToken{} = session} = Auth.fetch_session_by_token(raw, account.id)
      assert session.membership.id == owner.id
      assert session.membership.account.id == account.id
      assert is_nil(session.user_identity)

      # A token presented for workspace B is refused when its row belongs to A.
      assert Auth.fetch_session_by_token(raw, other.id) == {:error, :not_found}
      assert Auth.fetch_session_by_token(raw, "not-a-uuid") == {:error, :not_found}

      assert Auth.fetch_session_by_token(Crypto.random_secret(), account.id) ==
               {:error, :not_found}
    end

    test "a 60-day-old session no longer authenticates" do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()
      raw = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)

      Fixtures.Auth.backdate_session_token!(raw, DateTime.add(DateTime.utc_now(), -59, :day))
      assert {:ok, _session} = Auth.fetch_session_by_token(raw, account.id)

      Fixtures.Auth.backdate_session_token!(raw, DateTime.add(DateTime.utc_now(), -61, :day))
      assert Auth.fetch_session_by_token(raw, account.id) == {:error, :not_found}
    end

    test "a pending invitee, a suspended or removed Member and a disabled or deleted workspace do not authenticate" do
      for state <- [:pending, :suspended, :removed, :disabled_account, :deleted_account] do
        account = Fixtures.Accounts.create_account()
        member = Fixtures.Memberships.create_membership(account_id: account.id)
        raw = Fixtures.Auth.create_session_token!(member, :magic_link, nil)
        assert {:ok, _session} = Auth.fetch_session_by_token(raw, account.id)

        case state do
          :pending ->
            member
            |> Ecto.Changeset.change(
              invitation_token_digest: "pending",
              invitation_accepted_at: nil
            )
            |> Repo.update!()

          :suspended ->
            Fixtures.Memberships.suspend_membership(member)

          :removed ->
            Fixtures.Memberships.mark_membership_as_deleted(member)

          :disabled_account ->
            Fixtures.Accounts.disable_account(account)

          :deleted_account ->
            Fixtures.Accounts.mark_account_as_deleted(account)
        end

        assert Auth.fetch_session_by_token(raw, account.id) == {:error, :not_found},
               "#{state} still authenticated"
      end
    end

    test "an SSO session ends when its frozen route no longer holds" do
      for change <- [
            :identity_retired,
            :identity_moved,
            :subject_changed,
            :issuer_changed,
            :provider_disabled,
            :identity_deleted
          ] do
        account = Fixtures.Accounts.create_account(plan: "team")
        %{provider: provider, member: member, identity: identity, raw: raw} = sso_member(account)
        assert {:ok, session} = Auth.fetch_session_by_token(raw, account.id)
        assert session.user_identity.provider.id == provider.id

        case change do
          :identity_retired ->
            Fixtures.SSO.retire_identity(identity)

          :identity_moved ->
            other = Fixtures.Memberships.create_membership(account_id: account.id)
            identity |> Ecto.Changeset.change(membership_id: other.id) |> Repo.update!()

          :subject_changed ->
            identity
            |> Ecto.Changeset.change(provider_identifier: "someone-else")
            |> Repo.update!()

          :issuer_changed ->
            provider
            |> Ecto.Changeset.change(issuer: "https://other-issuer.test")
            |> Repo.update!()

          :provider_disabled ->
            Fixtures.SSO.disable_provider(provider)

          :identity_deleted ->
            identity |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()
        end

        assert Auth.fetch_session_by_token(raw, account.id) == {:error, :not_found},
               "#{change} still authenticated"

        assert Repo.reload!(member)
      end
    end
  end

  describe "session_expires_at/1" do
    test "is the instant the per-request predicate stops accepting the session" do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()
      raw = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)
      {:ok, session} = Auth.fetch_session_by_token(raw, account.id)

      expires_at = Auth.session_expires_at(session)
      assert expires_at == DateTime.add(session.inserted_at, 60, :day)

      session
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -60, :day))
      |> Repo.update!()

      assert Auth.fetch_session_by_token(raw, account.id) == {:error, :not_found}
    end
  end

  describe "list_live_sessions/1" do
    test "returns each entry's own live row and silently drops dead or mismatched ones" do
      {owner_a, account_a, _} = Fixtures.Subjects.owner_subject()
      {owner_b, account_b, _} = Fixtures.Subjects.owner_subject()
      raw_a = Fixtures.Auth.create_session_token!(owner_a, :magic_link, nil)
      raw_b = Fixtures.Auth.create_session_token!(owner_b, :magic_link, nil)
      dead = Fixtures.Auth.create_session_token!(owner_b, :magic_link, nil)
      Fixtures.Auth.delete_session_token!(dead)

      assert {:ok, sessions} =
               Auth.list_live_sessions([
                 {account_a.id, raw_a},
                 {account_b.id, raw_b},
                 {account_b.id, dead},
                 # A's token under B's workspace must not resolve.
                 {account_b.id, raw_a},
                 {"not-a-uuid", raw_a},
                 {account_a.id, nil}
               ])

      assert Enum.sort(Enum.map(sessions, & &1.membership_id)) ==
               Enum.sort([owner_a.id, owner_b.id])

      assert Enum.all?(sessions, &match?(%Accounts.Account{}, &1.membership.account))
      assert Auth.list_live_sessions([]) == {:ok, []}
    end
  end

  describe "fetch_current_session/1" do
    test "re-reads the Subject's own live session and refuses once it ended" do
      {owner, _account, subject} = Fixtures.Subjects.owner_subject()
      assert {:ok, %UserToken{id: id}} = Auth.fetch_current_session(subject)
      assert id == subject.session_token_id

      :ok = Auth.revoke_session_tokens([], :dead_entry, %RequestContext{})
      assert {:ok, _still} = Auth.fetch_current_session(subject)

      Fixtures.Memberships.suspend_membership(owner)
      assert Auth.fetch_current_session(subject) == {:error, :unauthorized}
    end
  end

  describe "revoke_session_tokens/3" do
    test "deletes the rows, audits each live one with its reason in its own workspace and disconnects after commit" do
      {owner_a, account_a, _} = Fixtures.Subjects.owner_subject()
      {owner_b, account_b, _} = Fixtures.Subjects.owner_subject()
      replaced = Fixtures.Auth.create_session_token!(owner_a, :magic_link, nil)
      evicted = Fixtures.Auth.create_session_token!(owner_b, :magic_link, nil)
      dead = Fixtures.Auth.create_session_token!(owner_b, :magic_link, nil)
      Fixtures.Auth.backdate_session_token!(dead, DateTime.add(DateTime.utc_now(), -61, :day))
      survivor = Fixtures.Auth.create_session_token!(owner_a, :magic_link, nil)
      context = %RequestContext{request_id: "req-revoke"}

      Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingSessionDisconnector}
      )

      assert Auth.revoke_session_tokens([replaced], :replaced, context) == :ok

      assert Auth.revoke_session_tokens(
               [evicted, dead, Crypto.random_secret()],
               :evicted,
               context
             ) ==
               :ok

      assert Auth.fetch_session_by_token(replaced, account_a.id) == {:error, :not_found}
      assert Auth.fetch_session_by_token(evicted, account_b.id) == {:error, :not_found}
      refute Repo.exists?(UserToken.Query.by_token_digest(Crypto.hash(dead)))
      assert {:ok, _} = Auth.fetch_session_by_token(survivor, account_a.id)

      assert [replaced_event] = events_of(account_a.id, "user.session_revoked")
      assert replaced_event.actor_id == owner_a.id
      assert replaced_event.payload["reason"] == "replaced"
      assert replaced_event.request_id == "req-revoke"
      # The expired row is swept without an audit row: only the live one counts.
      assert [evicted_event] = events_of(account_b.id, "user.session_revoked")
      assert evicted_event.actor_id == owner_b.id
      assert evicted_event.payload["reason"] == "evicted"

      replaced_topic = Auth.live_socket_topic(Crypto.hash(replaced))
      assert_receive {:session_disconnect, [^replaced_topic], false}
      assert_receive {:session_disconnect, topics, false}
      assert Auth.live_socket_topic(Crypto.hash(evicted)) in topics
    end
  end

  describe "complete_browser_sign_out/3" do
    test "ends every live session the cookie names, across workspaces, auditing each Member once" do
      {owner_a, account_a, _} = Fixtures.Subjects.owner_subject()
      {owner_b, account_b, _} = Fixtures.Subjects.owner_subject()
      raw_a = Fixtures.Auth.create_session_token!(owner_a, :magic_link, nil)
      raw_b = Fixtures.Auth.create_session_token!(owner_b, :magic_link, nil)
      untouched = Fixtures.Auth.create_session_token!(owner_a, :magic_link, nil)

      Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingSessionDisconnector}
      )

      assert {:ok, members} =
               Auth.complete_browser_sign_out([raw_a, raw_b], nil, %RequestContext{})

      assert Enum.sort(Enum.map(members, & &1.id)) == Enum.sort([owner_a.id, owner_b.id])
      assert Enum.all?(members, &match?(%Accounts.Account{}, &1.account))

      assert Auth.fetch_session_by_token(raw_a, account_a.id) == {:error, :not_found}
      assert Auth.fetch_session_by_token(raw_b, account_b.id) == {:error, :not_found}
      assert {:ok, _} = Auth.fetch_session_by_token(untouched, account_a.id)

      assert [event_a] = events_of(account_a.id, "user.signed_out")
      assert {event_a.actor_id, event_a.target_id} == {owner_a.id, owner_a.id}
      assert [event_b] = events_of(account_b.id, "user.signed_out")
      assert event_b.actor_id == owner_b.id

      assert_receive {:session_disconnect, topics, false}

      assert Enum.sort(topics) ==
               Enum.sort([
                 Auth.live_socket_topic(Crypto.hash(raw_a)),
                 Auth.live_socket_topic(Crypto.hash(raw_b))
               ])

      # A second sign-out of the same cookie finds nothing live and audits nothing.
      assert Auth.complete_browser_sign_out([raw_a, raw_b], nil, %RequestContext{}) == {:ok, []}
      assert [_only] = events_of(account_a.id, "user.signed_out")
    end

    test "also ends a session this browser minted that the cookie no longer names" do
      {owner, account, _} = Fixtures.Subjects.owner_subject()
      browser_id = Crypto.random_secret()

      kept =
        Fixtures.Auth.create_session_token!(owner, :magic_link, nil, %{}, browser_id: browser_id)

      # A concurrent tab's sign-in: same browser, an entry the final cookie lost.
      orphan =
        Fixtures.Auth.create_session_token!(owner, :magic_link, nil, %{}, browser_id: browser_id)

      other_browser = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)

      assert {:ok, members} =
               Auth.complete_browser_sign_out([kept], browser_id, %RequestContext{})

      assert Enum.map(members, & &1.id) == [owner.id, owner.id]

      assert Auth.fetch_session_by_token(kept, account.id) == {:error, :not_found}
      assert Auth.fetch_session_by_token(orphan, account.id) == {:error, :not_found}
      assert {:ok, _} = Auth.fetch_session_by_token(other_browser, account.id)
      assert length(events_of(account.id, "user.signed_out")) == 2
    end

    test "an expired or foreign token is swept silently and a dead cookie signs nobody out" do
      {owner, account, _} = Fixtures.Subjects.owner_subject()
      expired = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)
      Fixtures.Auth.backdate_session_token!(expired, DateTime.add(DateTime.utc_now(), -61, :day))

      assert Auth.complete_browser_sign_out(
               [expired, Crypto.random_secret()],
               nil,
               %RequestContext{}
             ) ==
               {:ok, []}

      refute Repo.exists?(UserToken.Query.by_token_digest(Crypto.hash(expired)))
      assert events_of(account.id, "user.signed_out") == []
    end
  end

  describe "delete_membership_sessions/2" do
    test "ends one Member's sessions and codes, returning their socket topics, and no other Member's" do
      {owner, account} = owner_member()
      other = Fixtures.Memberships.create_membership(account_id: account.id)
      raw = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)
      _code = Fixtures.Auth.create_aged_token!(owner, "magic_link", DateTime.utc_now())
      theirs = Fixtures.Auth.create_session_token!(other, :magic_link, nil)

      assert {:ok, %{count: 2, socket_topics: [topic]}} =
               Auth.delete_membership_sessions(owner, Repo)

      assert topic == Auth.live_socket_topic(Crypto.hash(raw))
      assert Auth.fetch_session_by_token(raw, account.id) == {:error, :not_found}
      refute Repo.exists?(UserToken.Query.by_membership(account.id, owner.id))
      assert {:ok, _} = Auth.fetch_session_by_token(theirs, account.id)
    end
  end

  describe "delete_identity_sessions/2" do
    test "ends the sessions signed in through the identities and keeps every other" do
      account = Fixtures.Accounts.create_account(plan: "team")
      %{member: member, identity: identity, raw: sso_raw} = sso_member(account)
      %{raw: other_sso} = sso_member(account, :openid_connect)
      email_raw = Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      assert {:ok, %{count: 1, socket_topics: [topic]}} =
               Auth.delete_identity_sessions([identity.id], Repo)

      assert topic == Auth.live_socket_topic(Crypto.hash(sso_raw))
      assert Auth.fetch_session_by_token(sso_raw, account.id) == {:error, :not_found}
      assert {:ok, _} = Auth.fetch_session_by_token(other_sso, account.id)
      assert {:ok, _} = Auth.fetch_session_by_token(email_raw, account.id)
      assert Auth.delete_identity_sessions([], Repo) == {:ok, %{count: 0, socket_topics: []}}
    end
  end

  describe "delete_account_email_sessions/2" do
    test "ends the workspace's email-code sessions only; SSO sessions and other workspaces survive" do
      account = Fixtures.Accounts.create_account(plan: "team")
      %{raw: sso_raw} = sso_member(account)
      member = Fixtures.Memberships.create_membership(account_id: account.id)
      email_raw = Fixtures.Auth.create_session_token!(member, :magic_link, nil)
      {other_owner, other_account, _} = Fixtures.Subjects.owner_subject()
      other_raw = Fixtures.Auth.create_session_token!(other_owner, :magic_link, nil)

      assert {:ok, %{count: 1, socket_topics: [topic]}} =
               Auth.delete_account_email_sessions(account.id, Repo)

      assert topic == Auth.live_socket_topic(Crypto.hash(email_raw))
      assert Auth.fetch_session_by_token(email_raw, account.id) == {:error, :not_found}
      assert {:ok, _} = Auth.fetch_session_by_token(sso_raw, account.id)
      assert {:ok, _} = Auth.fetch_session_by_token(other_raw, other_account.id)
    end
  end

  describe "list_sessions_for_member/3" do
    setup context do
      {owner, account} = owner_member()
      metadata = Map.get(context, :session_metadata, %{})
      token = Fixtures.Auth.create_session_token!(owner, :magic_link, nil, metadata)
      subject = Fixtures.Subjects.subject_for(owner, session: token)
      %{member: owner, account: account, subject: subject, token: token}
    end

    test "returns the Member's own rows newest-first", %{member: member, subject: subject} do
      Fixtures.Auth.create_session_token!(member, :magic_link, nil)
      Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      assert {:ok, sessions, _meta} = Auth.list_sessions_for_member(nil, subject)
      assert length(sessions) == 3
      assert Enum.sort_by(sessions, & &1.inserted_at, {:desc, DateTime}) == sessions
    end

    test "expired rows are absent from the page, total, and next cursor", %{
      member: member,
      account: account,
      subject: subject,
      token: live
    } do
      expired = Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      :ok =
        Fixtures.Auth.backdate_session_token!(
          expired,
          DateTime.add(DateTime.utc_now(), -61, :day)
        )

      assert {:ok, [session], metadata} =
               Auth.list_sessions_for_member(Crypto.hash(live), subject, page: [limit: 1])

      assert session.current?
      assert metadata.count == 1
      assert metadata.next_page_cursor == nil
      assert Auth.fetch_session_by_token(expired, account.id) == {:error, :not_found}
    end

    test "only returns the Member's own sessions, not another Member's at the same address", %{
      member: member,
      account: account,
      subject: my_subject
    } do
      theirs = Fixtures.Memberships.create_membership(account_id: account.id)
      Fixtures.Auth.create_session_token!(theirs, :magic_link, nil)
      elsewhere = Fixtures.Memberships.create_membership(email: member.email)
      Fixtures.Auth.create_session_token!(elsewhere, :magic_link, nil)

      assert {:ok, [_], _meta} = Auth.list_sessions_for_member(nil, my_subject)
    end

    test "only includes session-context tokens (not the pending magic-link)", %{
      member: member,
      account: account,
      subject: subject,
      token: token
    } do
      assert {:ok, _} = Auth.request_magic_link(account, member.email, %RequestContext{})

      assert {:ok, [session], _meta} = Auth.list_sessions_for_member(Crypto.hash(token), subject)
      assert session.current?
    end

    @tag session_metadata: %{ip_address: "198.51.100.7"}
    test "marks the presented session current and leaves the others alone", %{
      member: member,
      subject: subject,
      token: current
    } do
      Fixtures.Auth.create_session_token!(member, :magic_link, nil, %{
        ip_address: "203.0.113.9"
      })

      assert {:ok, sessions, _meta} = Auth.list_sessions_for_member(Crypto.hash(current), subject)
      assert [%{ip_address: "198.51.100.7"}] = Enum.filter(sessions, & &1.current?)
      assert [%{ip_address: "203.0.113.9"}] = Enum.reject(sessions, & &1.current?)
    end

    test "a nil presented token marks every row not-current", %{subject: subject} do
      assert {:ok, [session], _meta} = Auth.list_sessions_for_member(nil, subject)
      refute session.current?
    end

    test "another Member's raw token never marks a row current", %{subject: subject} do
      theirs = Fixtures.Auth.create_session_token!(Fixtures.Memberships.create_membership())

      assert {:ok, [session], _meta} =
               Auth.list_sessions_for_member(Crypto.hash(theirs), subject)

      refute session.current?
    end

    @tag session_metadata: %{
           ip_address: "198.51.100.7",
           user_agent: "Mozilla/5.0 Firefox/126.0"
         }
    test "projects display facts only — never the token, digest, or metadata map", %{
      subject: subject,
      token: token
    } do
      assert {:ok, [session], _meta} = Auth.list_sessions_for_member(Crypto.hash(token), subject)

      assert %Auth.SessionFacts{
               current?: true,
               ip_address: "198.51.100.7",
               user_agent: "Mozilla/5.0 Firefox/126.0",
               auth_method: :magic_link,
               inserted_at: %DateTime{}
             } = session

      # The whole field set — a credential field can never be added back in.
      assert session |> Map.keys() |> Enum.sort() ==
               [:__struct__, :auth_method, :current?, :id, :inserted_at, :ip_address, :user_agent]
    end

    test "projects the recorded SSO method without identity or assurance fields", %{
      member: member,
      account: account,
      subject: subject
    } do
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: member
        })

      token =
        Fixtures.Auth.create_session_token!(member, :sso, DateTime.utc_now(), %{},
          user_identity_id: identity.id
        )

      assert {:ok, [session, email_session], _} =
               Auth.list_sessions_for_member(Crypto.hash(token), subject)

      assert email_session.id == subject.session_token_id
      assert session.current?
      assert session.auth_method == :sso
      refute Map.has_key?(session, :user_identity_id)
      refute Map.has_key?(session, :mfa_verified_at)
    end

    test "a session with no device metadata projects nil display fields", %{
      subject: subject,
      token: token
    } do
      assert {:ok, [session], _meta} = Auth.list_sessions_for_member(Crypto.hash(token), subject)
      assert session.ip_address == nil
      assert session.user_agent == nil
    end

    test "an SSO session of the Member lists the same sessions", %{
      member: member,
      account: account,
      subject: subject,
      token: token
    } do
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: member
        })

      sso_subject =
        Fixtures.Subjects.subject_for(member, auth_method: :sso, user_identity_id: identity.id)

      assert {:ok, sessions, _meta} = Auth.list_sessions_for_member(Crypto.hash(token), subject)
      assert {:ok, same, _meta} = Auth.list_sessions_for_member(Crypto.hash(token), sso_subject)
      assert same == sessions

      assert Enum.sort(Enum.map(sessions, & &1.id)) ==
               Enum.sort([subject.session_token_id, sso_subject.session_token_id])
    end

    test "refuses a non-Member subject and an ended session", %{
      member: member,
      account: account,
      subject: subject,
      token: token
    } do
      {_raw_key, api_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      api_subject = Auth.Subject.for_api_key(api_key, account)

      assert Auth.list_sessions_for_member(nil, api_subject) == {:error, :unauthorized}

      Fixtures.Auth.delete_session_token!(token)
      assert Auth.list_sessions_for_member(nil, subject) == {:error, :unauthorized}
      assert Repo.reload!(member)
    end
  end

  describe "revoke_session/2" do
    setup do
      {owner, account} = owner_member()
      current = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)
      subject = Fixtures.Subjects.subject_for(owner, session: current)
      %{member: owner, account: account, subject: subject, current: current}
    end

    test ":ok and the row goes away, audited", %{
      member: member,
      account: account,
      subject: subject
    } do
      token = Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      assert {:ok, [session, caller], _} =
               Auth.list_sessions_for_member(Crypto.hash(token), subject)

      assert caller.id == subject.session_token_id

      assert Auth.revoke_session(session.id, subject) == :ok
      assert {:ok, [^caller], _} = Auth.list_sessions_for_member(Crypto.hash(token), subject)
      assert [event] = events_of(account.id, "user.session_revoked")
      assert event.payload["session_id"] == session.id
    end

    test "disconnects the exact token topic only after commit", %{
      member: member,
      subject: subject
    } do
      token = Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      assert {:ok, [session, caller], _} =
               Auth.list_sessions_for_member(Crypto.hash(token), subject)

      assert caller.id == subject.session_token_id

      Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingSessionDisconnector}
      )

      assert Auth.revoke_session(session.id, subject) == :ok

      topic = Auth.live_socket_topic(Crypto.hash(token))
      assert_receive {:session_disconnect, [^topic], false}
      refute_receive {:session_disconnect, _topics, _in_transaction?}
    end

    test "refuses another Member's session id, in this or another workspace", %{
      account: account,
      subject: my_subject
    } do
      teammate = Fixtures.Memberships.create_membership(account_id: account.id)
      their_subject = Fixtures.Subjects.subject_for(teammate)
      {_elsewhere, _other_account, elsewhere_subject} = Fixtures.Subjects.owner_subject()

      for other <- [their_subject, elsewhere_subject] do
        assert {:ok, [their_session], _} = Auth.list_sessions_for_member(nil, other)
        assert Auth.revoke_session(their_session.id, my_subject) == {:error, :not_found}
        assert {:ok, [_], _} = Auth.list_sessions_for_member(nil, other)
      end
    end

    test "rejects a malformed id without hitting the DB", %{subject: subject} do
      assert Auth.revoke_session("not-a-uuid", subject) == {:error, :not_found}
    end

    test "refuses a non-Member subject without touching the session", %{
      account: account,
      subject: subject,
      current: current
    } do
      assert {:ok, [session], _} = Auth.list_sessions_for_member(Crypto.hash(current), subject)
      {_raw_key, api_key} = Fixtures.ApiKeys.create_api_key(account_id: account.id)
      api_subject = Auth.Subject.for_api_key(api_key, account)

      assert Auth.revoke_session(session.id, api_subject) == {:error, :unauthorized}
      assert {:ok, _} = Auth.fetch_session_by_token(current, account.id)
    end
  end

  describe "revoke_and_disconnect_other_sessions/2" do
    setup do
      {owner, account} = owner_member()
      token = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)
      subject = Fixtures.Subjects.subject_for(owner, session: token)
      %{member: owner, account: account, subject: subject, token: token}
    end

    test "with only the current session, revokes nothing", %{
      account: account,
      subject: subject,
      token: keep
    } do
      assert Auth.revoke_and_disconnect_other_sessions(Crypto.hash(keep), subject) == {:ok, 0}
      assert {:ok, _} = Auth.fetch_session_by_token(keep, account.id)
    end

    test "keeps the caller's current session", %{member: member, subject: subject, token: keep} do
      Fixtures.Auth.create_session_token!(member, :magic_link, nil)
      Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      assert Auth.revoke_and_disconnect_other_sessions(Crypto.hash(keep), subject) == {:ok, 2}
      assert {:ok, [survivor], _} = Auth.list_sessions_for_member(Crypto.hash(keep), subject)
      assert survivor.current?
    end

    test "a revoked caller cannot end the remaining browser", %{
      member: member,
      account: account,
      subject: subject,
      token: keep
    } do
      other = Fixtures.Auth.create_session_token!(member, :magic_link, nil)
      Fixtures.Auth.delete_session_token!(keep)

      assert Auth.revoke_and_disconnect_other_sessions(Crypto.hash(keep), subject) ==
               {:error, :unauthorized}

      assert {:ok, _} = Auth.fetch_session_by_token(other, account.id)
    end

    test "revokes the Member's SSO sessions too, leaves other Members alone, and disconnects after commit",
         %{member: member, account: account, subject: subject, token: keep} do
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

      identity =
        Fixtures.SSO.create_user_identity(%{
          account_id: account.id,
          provider_id: provider.id,
          membership: member
        })

      other =
        Fixtures.Auth.create_session_token!(member, :sso, nil, %{}, user_identity_id: identity.id)

      teammate = Fixtures.Memberships.create_membership(account_id: account.id)
      foreign = Fixtures.Auth.create_session_token!(teammate, :magic_link, nil)
      {elsewhere, other_account, _} = Fixtures.Subjects.owner_subject()
      elsewhere_raw = Fixtures.Auth.create_session_token!(elsewhere, :magic_link, nil)

      Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingSessionDisconnector}
      )

      assert Auth.revoke_and_disconnect_other_sessions(Crypto.hash(keep), subject) == {:ok, 1}
      topic = Auth.live_socket_topic(Crypto.hash(other))
      assert_receive {:session_disconnect, [^topic], false}
      assert {:ok, _} = Auth.fetch_session_by_token(keep, account.id)
      assert {:ok, _} = Auth.fetch_session_by_token(foreign, account.id)
      assert {:ok, _} = Auth.fetch_session_by_token(elsewhere_raw, other_account.id)
    end

    test "audit rejection preserves sessions and emits no disconnect", %{
      member: member,
      account: account,
      subject: subject,
      token: keep
    } do
      other = Fixtures.Auth.create_session_token!(member, :magic_link, nil)

      Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingSessionDisconnector}
      )

      subject = %{subject | context: %RequestContext{request_id: %{invalid: true}}}

      assert {:error, %Ecto.Changeset{}} =
               Auth.revoke_and_disconnect_other_sessions(Crypto.hash(keep), subject)

      refute_received {:session_disconnect, _, _}
      assert {:ok, _} = Auth.fetch_session_by_token(keep, account.id)
      assert {:ok, _} = Auth.fetch_session_by_token(other, account.id)
    end
  end

  describe "subscribe_session/1" do
    test "subscribes the caller to exactly its session's disconnect topic" do
      {owner, account, _} = Fixtures.Subjects.owner_subject()
      raw = Fixtures.Auth.create_session_token!(owner, :magic_link, nil)
      {:ok, session} = Auth.fetch_session_by_token(raw, account.id)

      assert Auth.subscribe_session(session) == :ok

      Emisar.PubSub.broadcast(Auth.live_socket_topic(session.token), {:hello, session.id})
      assert_receive {:hello, id}
      assert id == session.id
    end
  end
end
