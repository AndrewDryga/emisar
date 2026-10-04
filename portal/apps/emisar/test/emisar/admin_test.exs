defmodule Emisar.AdminTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.Membership
  alias Emisar.{Admin, Audit, Billing, Crypto, Fixtures, RequestContext}

  defmodule RecordingDisconnector do
    def disconnect_live_sessions(topics) do
      send(self(), {:staff_disconnect, topics, Emisar.Repo.in_transaction?()})
      :ok
    end
  end

  describe "job_modules/0" do
    test "lists every recurrent job the application declares" do
      declared = declared_job_modules()

      assert Enum.sort(Admin.job_modules()) == Enum.sort(declared)
      assert length(declared) == length(Enum.uniq(declared))
    end

    test "every declared job is supervised by the context that owns it" do
      for module <- declared_job_modules() do
        owning_context = module |> Module.split() |> Enum.take(2) |> Module.safe_concat()
        {:ok, {_flags, children}} = owning_context.init([])

        assert module in Enum.map(children, & &1.id),
               "#{inspect(module)} is not a child of #{inspect(owning_context)}"
      end
    end

    test "every recurrent job is disabled in the test environment" do
      enabled = Enum.filter(Admin.job_modules(), &job_enabled?/1)

      assert enabled == [],
             "these jobs tick inside the test sandbox; disable them in config/test.exs: #{inspect(enabled)}"
    end
  end

  defp job_enabled?(module), do: Emisar.Config.get_env(:emisar, module, [])[:enabled] != false

  # Derived from the compiled application rather than a second hand-typed
  # registry: `__config__/0` is generated only by `use Emisar.Jobs.Job`, so a
  # new job cannot be declared without this list seeing it.
  defp declared_job_modules do
    {:ok, modules} = :application.get_key(:emisar, :modules)
    Enum.filter(modules, &recurrent_job_module?/1)
  end

  defp recurrent_job_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__config__, 0)
  end

  describe "create_staff/1" do
    test "creates a staff login and returns its authenticator secret once" do
      assert {:ok, staff, secret} = Admin.create_staff("  ops@emisar.test ")

      assert staff.email == "ops@emisar.test"
      assert staff.mfa_secret == secret
      assert staff.failed_mfa_attempts == 0
      assert Repo.reload!(staff).mfa_secret == secret
    end

    test "refuses an address another staff login uses, in any letter case" do
      assert {:ok, _staff, _secret} = Admin.create_staff("ops@emisar.test")

      assert {:error, changeset} = Admin.create_staff("OPS@emisar.test")
      assert errors_on(changeset) == %{email: ["has already been taken"]}
    end

    test "refuses something that is not an address" do
      assert {:error, changeset} = Admin.create_staff("not an address")
      assert %{email: [_message]} = errors_on(changeset)
      assert Admin.list_staff() == []
    end
  end

  describe "reset_staff/1" do
    setup do
      Emisar.Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingDisconnector}
      )
    end

    test "gives a new secret, unlocks the login, and ends its sessions and codes" do
      staff =
        Fixtures.Admin.create_staff()
        |> Fixtures.Admin.update_staff(
          failed_mfa_attempts: 5,
          mfa_last_used_at: DateTime.utc_now()
        )

      {raw, _session} = Fixtures.Admin.create_staff_session(staff)
      request_code(staff)

      assert {:ok, reset, secret} = Admin.reset_staff(String.upcase(staff.email))

      assert secret != staff.mfa_secret
      assert reset.mfa_secret == secret
      assert reset.failed_mfa_attempts == 0
      assert is_nil(reset.mfa_last_used_at)
      assert Admin.fetch_staff_session(raw) == {:error, :not_found}
      refute Repo.exists?(Admin.StaffToken.Query.by_staff_id(staff.id))

      topic = Admin.staff_session_socket_topic(raw)
      assert_received {:staff_disconnect, [^topic], false}
    end

    test "an address with no staff login is not found" do
      assert Admin.reset_staff("nobody@emisar.test") == {:error, :not_found}
      refute_received {:staff_disconnect, _topics, _in_transaction?}
    end
  end

  describe "remove_staff/1" do
    setup do
      Emisar.Config.put_override(
        :emisar,
        :session_disconnect_handler,
        {:emisar, RecordingDisconnector}
      )
    end

    test "deletes the login with its sessions and codes, and disconnects its sockets" do
      staff = Fixtures.Admin.create_staff()
      {raw, _session} = Fixtures.Admin.create_staff_session(staff)
      request_code(staff)

      assert Admin.remove_staff(staff.email) == :ok

      assert Admin.list_staff() == []
      refute Repo.exists?(Admin.StaffToken.Query.all())
      topic = Admin.staff_session_socket_topic(raw)
      assert_received {:staff_disconnect, [^topic], false}
    end

    test "an address with no staff login is not found" do
      assert Admin.remove_staff("nobody@emisar.test") == {:error, :not_found}
    end
  end

  describe "list_staff/0" do
    test "lists every staff login by address" do
      assert {:ok, zed, _secret} = Admin.create_staff("zed@emisar.test")
      assert {:ok, amy, _secret} = Admin.create_staff("amy@emisar.test")

      assert Enum.map(Admin.list_staff(), & &1.id) == [amy.id, zed.id]
    end
  end

  describe "staff_locked?/1" do
    test "locks at five wrong authenticator codes in a row" do
      staff = Fixtures.Admin.create_staff()

      refute Admin.staff_locked?(staff)
      refute Admin.staff_locked?(Fixtures.Admin.update_staff(staff, failed_mfa_attempts: 4))
      assert Admin.staff_locked?(Fixtures.Admin.update_staff(staff, failed_mfa_attempts: 5))
    end
  end

  describe "request_staff_sign_in/2" do
    test "emails a staff address a code that only the returned nonce completes" do
      staff = Fixtures.Admin.create_staff()

      assert {:ok, %{token_id: token_id, nonce: nonce}} =
               Admin.request_staff_sign_in(" #{String.upcase(staff.email)} ", %RequestContext{})

      assert_received {:email, sent}
      assert sent.to == [{"", staff.email}]
      code = Fixtures.Auth.code_from_email(sent)
      refute sent.text_body =~ token_id

      token = Repo.get!(Admin.StaffToken, token_id)
      assert token.context == :sign_in
      assert token.remaining_attempts == 5
      assert token.token == Crypto.magic_link_digest(nonce, code)
    end

    test "a new request leaves every other browser's pending code working" do
      staff = Fixtures.Admin.create_staff()
      {first_id, first_nonce, first_code} = request_code(staff)
      {second_id, _nonce, _code} = request_code(staff)

      assert Enum.sort([first_id, second_id]) ==
               Admin.StaffToken.Query.by_staff_id(staff.id)
               |> Repo.all()
               |> Enum.map(& &1.id)
               |> Enum.sort()

      otp = Fixtures.Admin.totp_code(staff)
      assert {:ok, _raw, _session} = sign_in(first_id, first_nonce, first_code, otp)

      # A completed sign-in cancels the rest.
      refute Repo.exists?(Admin.StaffToken.Query.by_context(:sign_in))
    end

    test "any other address gets the same shape, and nothing is written or sent" do
      assert {:ok, %{token_id: token_id, nonce: nonce}} =
               Admin.request_staff_sign_in("nobody@emisar.test", %RequestContext{})

      assert Repo.valid_uuid?(token_id)
      assert byte_size(nonce) > 20
      refute_received {:email, _sent}
      refute Repo.exists?(Admin.StaffToken.Query.all())
    end

    test "a sixth request from one client address inside 15 minutes sends nothing, and another address still gets a code" do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      staff = Fixtures.Admin.create_staff()
      flooding = %RequestContext{ip_address: "198.51.100.#{System.unique_integer([:positive])}"}

      for _attempt <- 1..5 do
        assert {:ok, _challenge} = Admin.request_staff_sign_in(staff.email, flooding)
        assert_received {:email, _sent}
      end

      assert {:ok, %{token_id: token_id}} = Admin.request_staff_sign_in(staff.email, flooding)
      refute_received {:email, _sent}
      refute Repo.get(Admin.StaffToken, token_id)

      # Somebody else asking for codes in staff's name cannot keep staff out.
      assert {:ok, %{token_id: own_id}} =
               Admin.request_staff_sign_in(staff.email, %RequestContext{})

      assert_received {:email, _sent}
      assert Repo.get(Admin.StaffToken, own_id)
    end
  end

  describe "complete_staff_sign_in/5" do
    setup do
      staff = Fixtures.Admin.create_staff()
      {token_id, nonce, code} = request_code(staff)
      %{staff: staff, token_id: token_id, nonce: nonce, code: code}
    end

    test "both codes start a 12-hour session and use up the email code", %{
      code: code,
      nonce: nonce,
      staff: staff,
      token_id: token_id
    } do
      otp = Fixtures.Admin.totp_code(staff)

      assert {:ok, raw, session} =
               sign_in(token_id, nonce, " #{String.downcase(code)} ", otp)

      assert session.context == :session
      assert session.staff.id == staff.id
      assert session.token == Crypto.hash(raw)
      assert_in_delta DateTime.diff(session.expires_at, DateTime.utc_now()), 12 * 3600, 10
      assert {:ok, %{id: session_id}} = Admin.fetch_staff_session(raw)
      assert session_id == session.id
      refute Repo.get(Admin.StaffToken, token_id)
      assert Repo.reload!(staff).mfa_last_used_at
    end

    test "a wrong email code spends an attempt and never reaches the authenticator", %{
      code: code,
      nonce: nonce,
      staff: staff,
      token_id: token_id
    } do
      otp = Fixtures.Admin.totp_code(staff)

      assert sign_in(token_id, nonce, other_code(code), otp) == {:error, :invalid}

      assert Repo.get!(Admin.StaffToken, token_id).remaining_attempts == 4
      assert Repo.reload!(staff).failed_mfa_attempts == 0
      assert is_nil(Repo.reload!(staff).mfa_last_used_at)
    end

    test "the right code with another browser's nonce does not sign in", %{
      code: code,
      staff: staff,
      token_id: token_id
    } do
      {other_nonce, _code, _digest} = Crypto.magic_link_token()
      otp = Fixtures.Admin.totp_code(staff)

      assert sign_in(token_id, other_nonce, code, otp) == {:error, :invalid}
      assert Repo.get!(Admin.StaffToken, token_id).remaining_attempts == 4
    end

    test "a code with no attempts left stops working, even with both codes right", %{
      code: code,
      nonce: nonce,
      staff: staff,
      token_id: token_id
    } do
      Admin.StaffToken
      |> Repo.get!(token_id)
      |> Fixtures.Admin.update_staff_token(remaining_attempts: 0)

      otp = Fixtures.Admin.totp_code(staff)
      assert sign_in(token_id, nonce, code, otp) == {:error, :invalid}
    end

    test "an expired code stops working", %{
      code: code,
      nonce: nonce,
      staff: staff,
      token_id: token_id
    } do
      Admin.StaffToken
      |> Repo.get!(token_id)
      |> Fixtures.Admin.update_staff_token(expires_at: DateTime.add(DateTime.utc_now(), -1))

      otp = Fixtures.Admin.totp_code(staff)
      assert sign_in(token_id, nonce, code, otp) == {:error, :invalid}
    end

    test "a wrong authenticator code after the right email code counts against the login", %{
      code: code,
      nonce: nonce,
      staff: staff,
      token_id: token_id
    } do
      assert sign_in(token_id, nonce, code, wrong_otp(staff)) ==
               {:error, :invalid}

      assert Repo.reload!(staff).failed_mfa_attempts == 1
      assert Repo.get!(Admin.StaffToken, token_id).remaining_attempts == 4

      otp = Fixtures.Admin.totp_code(staff)
      assert {:ok, _raw, _session} = sign_in(token_id, nonce, code, otp)
      assert Repo.reload!(staff).failed_mfa_attempts == 0
    end

    test "five wrong authenticator codes lock the login until a reset", %{
      code: code,
      nonce: nonce,
      staff: staff,
      token_id: token_id
    } do
      for _attempt <- 1..4 do
        assert sign_in(token_id, nonce, code, wrong_otp(staff)) ==
                 {:error, :invalid}
      end

      assert sign_in(token_id, nonce, code, wrong_otp(staff)) ==
               {:error, :locked}

      {token_id, nonce, code} = request_code(staff)
      otp = Fixtures.Admin.totp_code(staff)
      assert sign_in(token_id, nonce, code, otp) == {:error, :locked}
      refute Repo.exists?(Admin.StaffToken.Query.by_context(:session))
    end

    test "a locked login answers a wrong email code like any other", %{
      code: code,
      nonce: nonce,
      staff: staff,
      token_id: token_id
    } do
      Fixtures.Admin.update_staff(staff, failed_mfa_attempts: 5)
      otp = Fixtures.Admin.totp_code(staff)

      assert sign_in(token_id, nonce, other_code(code), otp) == {:error, :invalid}
    end

    test "an authenticator code works once", %{
      code: code,
      nonce: nonce,
      staff: staff,
      token_id: token_id
    } do
      otp = Fixtures.Admin.totp_code(staff)
      assert {:ok, _raw, _session} = sign_in(token_id, nonce, code, otp)

      {token_id, nonce, code} = request_code(staff)
      assert sign_in(token_id, nonce, code, otp) == {:error, :invalid}
      assert Repo.reload!(staff).failed_mfa_attempts == 1
    end

    test "a login removed after the code was sent cannot sign in", %{
      code: code,
      nonce: nonce,
      staff: staff,
      token_id: token_id
    } do
      assert Admin.remove_staff(staff.email) == :ok
      otp = Fixtures.Admin.totp_code(staff)

      assert sign_in(token_id, nonce, code, otp) == {:error, :invalid}
    end

    test "an id that names no code is refused", %{code: code, nonce: nonce, staff: staff} do
      otp = Fixtures.Admin.totp_code(staff)

      assert sign_in(Ecto.UUID.generate(), nonce, code, otp) == {:error, :invalid}
      assert sign_in("not-an-id", nonce, code, otp) == {:error, :invalid}
    end
  end

  describe "fetch_staff_session/1" do
    test "finds a live session with its staff" do
      staff = Fixtures.Admin.create_staff()
      {raw, session} = Fixtures.Admin.create_staff_session(staff)

      assert {:ok, found} = Admin.fetch_staff_session(raw)
      assert found.id == session.id
      assert found.staff.id == staff.id
    end

    test "an expired session is not found" do
      expired = DateTime.add(DateTime.utc_now(), -1)

      {raw, _session} =
        Fixtures.Admin.create_staff_session(Fixtures.Admin.create_staff(), expires_at: expired)

      assert Admin.fetch_staff_session(raw) == {:error, :not_found}
    end

    test "a value that is no session token is not found" do
      assert Admin.fetch_staff_session(Crypto.random_secret()) == {:error, :not_found}
    end
  end

  describe "refresh_staff_session/1" do
    test "re-reads a held session" do
      {_raw, session} = Fixtures.Admin.create_staff_session(Fixtures.Admin.create_staff())

      assert {:ok, fresh} = Admin.refresh_staff_session(session)
      assert fresh.id == session.id
    end

    test "a held session that was signed out since is not found" do
      {raw, session} = Fixtures.Admin.create_staff_session(Fixtures.Admin.create_staff())
      assert Admin.delete_staff_session(raw) == :ok

      assert Admin.refresh_staff_session(session) == {:error, :not_found}
    end

    test "anything that is not a stored session is not found" do
      assert Admin.refresh_staff_session(%Admin.StaffToken{id: "nope", context: :session}) ==
               {:error, :not_found}

      assert Admin.refresh_staff_session(nil) == {:error, :not_found}
    end
  end

  describe "delete_staff_session/1" do
    test "signs out that session and leaves the login's others" do
      staff = Fixtures.Admin.create_staff()
      {raw, _session} = Fixtures.Admin.create_staff_session(staff)
      {other_raw, _other} = Fixtures.Admin.create_staff_session(staff)

      assert Admin.delete_staff_session(raw) == :ok

      assert Admin.fetch_staff_session(raw) == {:error, :not_found}
      assert {:ok, _session} = Admin.fetch_staff_session(other_raw)
      assert Admin.delete_staff_session(raw) == :ok
    end
  end

  describe "staff_session_socket_topic/1" do
    test "names the session by its stored digest" do
      {raw, session} = Fixtures.Admin.create_staff_session(Fixtures.Admin.create_staff())

      assert Admin.staff_session_socket_topic(raw) ==
               "staff_sessions:" <> Crypto.encode_digest(session.token)
    end
  end

  # These reads are DELIBERATELY cross-account — staff see the whole platform —
  # so §7's cross-account isolation path does not apply here. The denial path is
  # the whole security surface: a live staff session row is the only thing
  # between a caller and every tenant's rows.
  describe "search_accounts/2" do
    setup do
      %{staff_session: live_staff_session()}
    end

    test "matches an account by slug", %{staff_session: staff_session} do
      account = Fixtures.Accounts.create_account()
      Fixtures.Accounts.create_account()

      assert {:ok, [found]} = Admin.search_accounts(account.slug, staff_session)
      assert found.id == account.id
    end

    test "matches an account by member email", %{staff_session: staff_session} do
      account = Fixtures.Accounts.create_account()
      member = Fixtures.Memberships.create_membership(account_id: account.id)

      assert {:ok, [found]} = Admin.search_accounts(member.email, staff_session)
      assert found.id == account.id
    end

    test "matches a typed LIKE wildcard literally", %{staff_session: staff_session} do
      account = Fixtures.Accounts.create_account(name: "Acme_One")
      Fixtures.Accounts.create_account(name: "AcmeXOne")

      # Unescaped, `_` matches any character and a bare `%` matches every row —
      # a support operator would act on the wrong tenant.
      assert {:ok, [found]} = Admin.search_accounts("Acme_One", staff_session)
      assert found.id == account.id

      assert Admin.search_accounts("%", staff_session) == {:ok, []}
    end

    test "a blank query lists the most recently created accounts", %{staff_session: staff_session} do
      account_one = Fixtures.Accounts.create_account()
      account_two = Fixtures.Accounts.create_account()

      assert {:ok, accounts} = Admin.search_accounts("   ", staff_session)
      assert Enum.map(accounts, & &1.id) == [account_two.id, account_one.id]
    end

    test "finds a disabled account", %{staff_session: staff_session} do
      account = Fixtures.Accounts.create_account() |> Fixtures.Accounts.disable_account()

      assert {:ok, [found]} = Admin.search_accounts(account.slug, staff_session)
      assert found.id == account.id
      assert found.disabled_at == account.disabled_at
    end

    test "denies an expired session" do
      account = Fixtures.Accounts.create_account()
      expired = DateTime.add(DateTime.utc_now(), -1, :second)

      {_raw, session} =
        Fixtures.Admin.create_staff_session(Fixtures.Admin.create_staff(), expires_at: expired)

      assert Admin.search_accounts(account.slug, session) == {:error, :unauthorized}
    end

    test "denies a held session after its staff login was reset" do
      account = Fixtures.Accounts.create_account()
      staff = Fixtures.Admin.create_staff()
      {_raw, session} = Fixtures.Admin.create_staff_session(staff)
      assert {:ok, _staff, _secret} = Admin.reset_staff(staff.email)

      # A connected staff LiveView holds exactly this struct — its mount-time
      # snapshot — for the life of the socket. The three staff reads share one
      # gate, which reads the row instead of believing the argument.
      assert Admin.search_accounts(account.slug, session) == {:error, :unauthorized}
    end

    test "denies a session struct that was never stored" do
      account = Fixtures.Accounts.create_account()
      forged = %Admin.StaffToken{id: Ecto.UUID.generate(), context: :session}

      assert Admin.search_accounts(account.slug, forged) == {:error, :unauthorized}
    end
  end

  describe "account_overview/2" do
    setup do
      %{staff_session: live_staff_session()}
    end

    test "each section carries the account's own rows", %{staff_session: staff_session} do
      account = Fixtures.Accounts.create_account(plan: "team")

      owner_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "owner"
        )

      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      runner = Fixtures.Runners.create_runner(account_id: account.id)
      run = Fixtures.Runs.create_run(account_id: account.id, runner_id: runner.id, source: :mcp)

      Fixtures.ApiKeys.create_api_key(
        account_id: account.id,
        created_by_membership_id: owner_membership.id
      )

      {:ok, event} = Audit.log(account.id, "policy.updated", actor_kind: "user")

      assert {:ok, overview} = Admin.account_overview(account.slug, staff_session)

      assert overview.account.id == account.id
      assert overview.billing.plan == "team"

      assert Enum.map(overview.members, & &1.id) == [owner_membership.id]
      assert Enum.map(overview.members, & &1.email) == [owner_membership.email]
      assert Enum.map(overview.sso, & &1.id) == [provider.id]

      assert overview.fleet.counts ==
               %{connected: 1, disconnected: 0, never_connected: 0, disabled: 0}

      assert Enum.map(overview.fleet.runners, & &1.id) == [runner.id]

      assert overview.runs.count_30d == 1
      assert Enum.map(overview.runs.recent, & &1.id) == [run.id]

      assert overview.mcp.active_api_keys == 1
      assert overview.mcp.recent_clients == [%{client: "unknown", runs: 1}]

      assert event.id in Enum.map(overview.audit_tail, & &1.id)
    end

    test "the roster keeps suspended members and unaccepted invitations", %{
      staff_session: staff_session
    } do
      account = Fixtures.Accounts.create_account()

      suspended_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "admin")
        |> Fixtures.Memberships.suspend_membership()

      invited_membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      assert {:ok, overview} = Admin.account_overview(account.slug, staff_session)

      assert Enum.map(overview.members, & &1.id) ==
               [suspended_membership.id, invited_membership.id]

      assert Enum.map(overview.members, &is_nil(&1.invitation_accepted_at)) == [true, true]
    end

    test "an account with nothing in it returns empty sections", %{staff_session: staff_session} do
      account = Fixtures.Accounts.create_account()

      assert {:ok, overview} = Admin.account_overview(account.id, staff_session)

      assert overview.billing ==
               %{
                 plan: "free",
                 subscribed_plan: "free",
                 entitlement_state: :free,
                 source: "free",
                 subscription_status: nil,
                 paddle_subscription_id: nil
               }

      assert overview.members == []
      assert overview.sso == []

      assert overview.fleet ==
               %{
                 counts: %{connected: 0, disconnected: 0, never_connected: 0, disabled: 0},
                 runners: []
               }

      assert overview.runs == %{count_30d: 0, recent: []}
      assert overview.mcp == %{active_api_keys: 0, recent_clients: []}
      assert overview.audit_tail == []
    end

    test "an unknown reference is not found", %{staff_session: staff_session} do
      assert Admin.account_overview("no-such-account", staff_session) == {:error, :not_found}
    end

    test "denies a session that was signed out" do
      account = Fixtures.Accounts.create_account()
      {raw, session} = Fixtures.Admin.create_staff_session(Fixtures.Admin.create_staff())
      assert Admin.delete_staff_session(raw) == :ok

      assert Admin.account_overview(account.slug, session) == {:error, :unauthorized}
    end
  end

  describe "record_account_view/2" do
    setup do
      %{staff_session: live_staff_session()}
    end

    test "records the view against the account, labelled by team not person", %{
      staff_session: staff_session
    } do
      account = Fixtures.Accounts.create_account()

      assert {:ok, event} = Admin.record_account_view(account, staff_session)

      assert event.account_id == account.id
      assert event.event_type == "staff.account_viewed"
      assert event.actor_kind == "staff"
      assert event.actor_label == "Emisar staff"
      assert event.target_kind == "account"
      assert event.target_id == account.id
      assert event.target_label == account.name
      assert event.payload == %{}

      # The row names the team and nothing else. A bare employee id here reaches
      # the console, the CSV export and the SIEM feed with no resolver, so a
      # customer could count staff and correlate one across tenants — the same
      # call every staff MUTATION already makes.
      assert is_nil(event.actor_id)
    end

    test "the account's own owner reads it back from their audit trail", %{
      staff_session: staff_session
    } do
      account = Fixtures.Accounts.create_account()
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
      subject = Fixtures.Subjects.subject_for(membership)

      assert {:ok, event} = Admin.record_account_view(account, staff_session)

      assert {:ok, [read_back], _metadata} =
               Audit.list_events(subject, filter: [event_type: ["staff.account_viewed"]])

      assert read_back.id == event.id
      assert read_back.actor_label == "Emisar staff"
    end

    test "denies a session whose staff login was removed, and records nothing" do
      account = Fixtures.Accounts.create_account()
      staff = Fixtures.Admin.create_staff()
      {_raw, session} = Fixtures.Admin.create_staff_session(staff)
      assert Admin.remove_staff(staff.email) == :ok

      assert Admin.record_account_view(account, session) == {:error, :unauthorized}
      refute Repo.one(Audit.Event)
    end
  end

  describe "execute/2" do
    test "erases a Member only when the confirmation matches its id" do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()

      assert Admin.execute(
               "emisar.admin.member.erase",
               [
                 "account=#{account.slug}",
                 "member=#{owner.id}",
                 "confirmation=not-the-member-id",
                 "reason=typo in the confirmation"
               ]
             ) == {:error, {:unsupported_admin_action, "emisar.admin.member.erase"}}

      assert Repo.reload(owner)

      assert {:ok, %{erased_member_id: erased, erased_account_id: erased_account}} =
               Admin.execute(
                 "emisar.admin.member.erase",
                 [
                   "account=#{account.slug}",
                   "member=#{owner.id}",
                   "confirmation=#{owner.id}",
                   "reason=verified erasure request"
                 ]
               )

      assert erased == owner.id
      refute Repo.reload(owner)
      # The sole owner's workspace goes with it, and the result says so.
      assert erased_account == account.id
      assert Emisar.Accounts.fetch_account_by_id(account.id) == {:error, :not_found}
    end

    test "erasing a Member beside another owner keeps the workspace" do
      {owner, account, _subject} = Fixtures.Subjects.owner_subject()
      Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      assert {:ok, %{erased_member_id: erased, erased_account_id: nil}} =
               Admin.execute(
                 "emisar.admin.member.erase",
                 [
                   "account=#{account.id}",
                   "member=#{owner.id}",
                   "confirmation=#{owner.id}",
                   "reason=verified erasure request"
                 ]
               )

      assert erased == owner.id
      assert {:ok, _account} = Emisar.Accounts.fetch_account_by_id(account.id)
    end

    test "dispatches a private RPC action from ordinary name-value argv" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, result} =
               Admin.execute("emisar.admin.account.show", ["account=#{account.slug}"])

      assert result.id == account.id
      assert result.slug == account.slug
      assert result.billing.plan == "free"
    end

    test "account.create makes a workspace whose owner is an invitation, once" do
      slug = "staff-made-#{System.unique_integer([:positive])}"
      email = Fixtures.Random.unique_email()
      args = ["email=#{email}", "name=Staff Made", "slug=#{slug}"]

      assert {:ok, %{created: true} = result} = Admin.execute("emisar.admin.account.create", args)
      assert result.slug == slug
      assert_received {:email, invitation}
      assert invitation.to == [{"", email}]

      assert [%Membership{role: :owner} = owner] =
               Membership.Query.not_deleted()
               |> Membership.Query.by_account_id(result.id)
               |> Repo.all()

      assert owner.email == email
      assert Emisar.Accounts.membership_invitation_pending?(owner)

      # The same slug again reports the existing workspace and invites nobody.
      assert {:ok, %{created: false, id: existing_id}} =
               Admin.execute("emisar.admin.account.create", args)

      assert existing_id == result.id
      refute_received {:email, _}
    end

    test "records private support mutations as platform work" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %{disabled: true}} =
               Admin.execute(
                 "emisar.admin.account.disable",
                 ["account=#{account.slug}", "reason=support=verified"]
               )

      # A disabled account's own owner is locked out, so read the trail directly.
      event = Enum.find(Repo.all(Audit.Event), &(&1.event_type == "account.disabled"))

      # The RPC has no user credential. The action run records its authenticated
      # dispatcher; the customer-domain event honestly records platform work.
      assert event.actor_kind == "system"
      assert is_nil(event.actor_id)
      assert is_nil(event.actor_label)
      assert event.payload == %{"reason" => "support=verified"}

      assert {:ok, %{disabled: true}} =
               Admin.execute(
                 "emisar.admin.account.disable",
                 ["account=#{account.slug}", "reason=repeated hold"]
               )

      assert Enum.count(Repo.all(Audit.Event), &(&1.event_type == "account.disabled")) == 1

      assert {:ok, %{disabled: false}} =
               Admin.execute(
                 "emisar.admin.account.enable",
                 ["account=#{account.slug}", "reason=support=resolved"]
               )

      assert {:ok, _account} = Emisar.Accounts.fetch_account_by_id(account.id)
    end

    test "diagnoses a Member from its sessions" do
      account = Fixtures.Accounts.create_account(plan: "team")
      provider = Fixtures.SSO.create_identity_provider(account_id: account.id)
      membership = Fixtures.Memberships.create_membership(account_id: account.id)

      identity =
        Fixtures.SSO.create_user_identity(
          account_id: account.id,
          provider_id: provider.id,
          membership: membership
        )

      Fixtures.Auth.create_session_token!(membership, :sso, nil, %{},
        user_identity_id: identity.id
      )

      args = ["account=#{account.slug}", "member=#{membership.id}"]

      assert {:ok, diagnosis} = Admin.execute("emisar.admin.access.diagnose", args)
      assert diagnosis.member.id == membership.id
      assert diagnosis.email_verified
      refute diagnosis.mfa_enabled
      assert diagnosis.active_sessions == 1
    end

    test "runs the member support verbs with a platform subject" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      membership =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")
        |> Fixtures.Memberships.set_mfa_state(
          mfa_secret: "JBSWY3DPEHPK3PXP",
          mfa_enabled_at: DateTime.utc_now(),
          mfa_recovery_codes: []
        )

      session_token = Fixtures.Auth.create_session_token!(membership, :magic_link, nil)
      args = ["account=#{account.slug}", "member=#{membership.email}"]

      assert {:ok, suspended} =
               Admin.execute("emisar.admin.member.suspend", args)

      assert suspended.id == membership.id
      assert Repo.reload!(membership).disabled_at

      # The written row carries no :user preload, so the email has to come from
      # the membership the dispatcher already fetched.
      assert suspended.email == membership.email

      assert {:ok, _} = Admin.execute("emisar.admin.member.reinstate", args)
      assert {:ok, _} = Admin.execute("emisar.admin.sessions.revoke", args)

      assert Emisar.Auth.fetch_session_by_token(session_token, account.id) ==
               {:error, :not_found}

      assert {:ok, _} =
               Admin.execute(
                 "emisar.admin.account.disable",
                 ["account=#{account.slug}", "reason=break-glass MFA reset"]
               )

      assert {:ok, _} = Admin.execute("emisar.admin.mfa.reset", args)

      reset_member = Repo.reload!(membership)
      assert is_nil(reset_member.mfa_secret)
      assert is_nil(reset_member.mfa_enabled_at)
      assert reset_member.mfa_recovery_codes == []
    end

    test "invites a member with full runner access" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, invited} =
               Admin.execute(
                 "emisar.admin.member.invite",
                 ["account=#{account.slug}", "email=locked-out-owner@example.com", "role=admin"]
               )

      assert invited.email == "locked-out-owner@example.com"
      assert invited.role == :admin
      assert invited.invitation_pending
      refute invited.disabled

      membership = Repo.one(Membership)
      assert membership.id == invited.id
      assert membership.runner_access_mode == :all
      # A platform-run invitation records no member as the inviter.
      assert is_nil(membership.invited_by_membership_id)
    end

    test "resends a pending invitation" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, invited} =
               Admin.execute(
                 "emisar.admin.member.invite",
                 ["account=#{account.slug}", "email=stalled-invite@example.com", "role=operator"]
               )

      first_digest = Repo.one(Membership).invitation_token_digest

      assert {:ok, resent} =
               Admin.execute(
                 "emisar.admin.invitation.resend",
                 ["account=#{account.slug}", "member=stalled-invite@example.com"]
               )

      assert resent.id == invited.id
      assert resent.email == "stalled-invite@example.com"
      assert resent.invitation_pending
      refute Repo.one(Membership).invitation_token_digest == first_digest
    end

    test "changes a member role" do
      account = Fixtures.Accounts.create_account()
      Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
      membership = Fixtures.Memberships.create_membership(account_id: account.id, role: "viewer")

      assert {:ok, promoted} =
               Admin.execute(
                 "emisar.admin.member.set_role",
                 ["account=#{account.slug}", "member=#{membership.email}", "role=admin"]
               )

      assert promoted.id == membership.id
      assert promoted.role == :admin
      assert promoted.email == membership.email
    end

    test "transfers ownership and demotes the previous owner" do
      account = Fixtures.Accounts.create_account()

      previous_membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "owner"
        )

      next_owner =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          role: "operator"
        )

      assert {:ok, promoted} =
               Admin.execute(
                 "emisar.admin.owner.transfer",
                 [
                   "account=#{account.slug}",
                   "new_owner=#{next_owner.email}",
                   "previous_owner=#{previous_membership.email}",
                   "previous_owner_access=all"
                 ]
               )

      assert promoted.role == :owner
      assert promoted.email == next_owner.email
      assert Repo.reload!(previous_membership).role == :admin
    end

    test "Owner demotion requires an explicit access choice" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()
      target = Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")
      args = ["account=#{account.slug}", "member=#{target.id}", "role=admin"]

      assert Admin.execute("emisar.admin.member.set_role", args) ==
               {:error, :owner_demotion_requires_access}

      assert Repo.reload!(target).role == :owner

      assert {:ok, demoted} =
               Admin.execute("emisar.admin.member.set_role", args ++ ["runner_access=none"])

      assert demoted.role == :admin

      assert Emisar.Accounts.runner_access_for_membership(account.id, target.id) ==
               Emisar.Accounts.RunnerAccess.none()
    end

    test "ownership transfer checks the previous Owner's access choice before promotion" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()

      previous_owner =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "owner")

      next_owner =
        Fixtures.Memberships.create_membership(account_id: account.id, role: "operator")

      assert Admin.execute("emisar.admin.owner.transfer", [
               "account=#{account.slug}",
               "new_owner=#{next_owner.id}",
               "previous_owner=#{previous_owner.id}"
             ]) == {:error, :owner_demotion_requires_access}

      assert Repo.reload!(next_owner).role == :operator
      assert Repo.reload!(previous_owner).role == :owner
    end

    test "Owner demotion cannot target a member in another account" do
      {_owner, account, _subject} = Fixtures.Subjects.owner_subject()
      foreign_owner = Fixtures.Memberships.create_membership(role: "owner")

      assert Admin.execute("emisar.admin.member.set_role", [
               "account=#{account.slug}",
               "member=#{foreign_owner.id}",
               "role=admin",
               "runner_access=none"
             ]) == {:error, :not_found}

      assert Repo.reload!(foreign_owner).role == :owner
    end

    test "rejects malformed, duplicate, excessive, and non-admin arguments" do
      assert Admin.execute("emisar.admin.account.show", ["account"]) ==
               {:error, :invalid_admin_arguments}

      assert Admin.execute("emisar.admin.account.show", ["account=one", "account=two"]) ==
               {:error, :invalid_admin_arguments}

      assert Admin.execute("emisar.admin.account.show", ["a=1", "b=2", "c=3", "d=4", "e=5"]) ==
               {:error, :invalid_admin_request}

      assert Admin.execute("linux.uptime", []) == {:error, :invalid_admin_request}
    end

    test "Slack support configuration is scoped, audited, repeatable and removable" do
      account = Fixtures.Accounts.create_account()
      other = Fixtures.Accounts.create_account()
      Fixtures.Accounts.set_account_settings(account, %{monthly_report_opt_out: true})
      url = "https://app.slack.com/client/T01234567/C01234567"
      args = ["account=#{account.slug}", "url=#{url}", "reason=Support channel agreed"]

      assert {:ok, %{id: id, support_slack_url: ^url}} =
               Admin.execute("emisar.admin.support.set_slack_channel", args)

      assert id == account.id
      assert Repo.reload!(account).settings.monthly_report_opt_out
      refute Repo.reload!(other).settings.support_slack_url

      events =
        Repo.all(Audit.Event)
        |> Enum.filter(&Map.has_key?(&1.payload["changes"] || %{}, "support_slack_url"))

      assert [event] = events
      assert event.account_id == account.id
      assert event.event_type == "account.updated"
      assert event.payload["changes"]["support_slack_url"] == %{"before" => nil, "after" => url}

      event_count = length(Repo.all(Audit.Event))
      assert {:ok, _} = Admin.execute("emisar.admin.support.set_slack_channel", args)
      assert length(Repo.all(Audit.Event)) == event_count

      assert {:ok, %{support_slack_url: nil}} =
               Admin.execute("emisar.admin.support.set_slack_channel", [
                 "account=#{account.id}",
                 "url=",
                 "reason=Channel retired"
               ])

      refute Repo.reload!(account).settings.support_slack_url
    end

    test "Slack support rejects unsafe destinations and missing audit reasons without changes" do
      account = Fixtures.Accounts.create_account()

      for url <- [
            "https://evil.example/archives/C01234567",
            "https://app.slack.com.evil.example/client/T01234567/C01234567",
            "https://evil.example@app.slack.com/client/T01234567/C01234567",
            "http://app.slack.com/client/T01234567/C01234567",
            "javascript:alert(1)",
            "https://app.slack.com:8443/client/T01234567/C01234567",
            "https://app.slack.com/client/T01234567/C01234567?redirect=https://evil.example",
            "https://app.slack.com/client/T01234567/C01234567#message",
            "https://join.slack.com/t/workspace/shared_invite/token",
            "https://workspace.slack.com/archives/C01234567/p12345",
            "https://app.slack.com/client/T01234567/../C01234567"
          ] do
        assert {:error, %Ecto.Changeset{}} =
                 Admin.execute("emisar.admin.support.set_slack_channel", [
                   "account=#{account.id}",
                   "url=#{url}",
                   "reason=Support setup"
                 ])
      end

      for reason <- ["", "   ", String.duplicate("a", 501)] do
        assert {:error, :invalid_reason} =
                 Admin.execute("emisar.admin.support.set_slack_channel", [
                   "account=#{account.id}",
                   "url=https://workspace.slack.com/archives/C01234567",
                   "reason=#{reason}"
                 ])
      end

      refute Repo.reload!(account).settings.support_slack_url
    end

    test "complimentary plans use the existing subscription posture" do
      account = Fixtures.Accounts.create_account()

      assert {:ok, %{plan: "team", source: "complimentary"}} =
               Admin.execute(
                 "emisar.admin.plan.grant",
                 ["account=#{account.slug}", "plan=team", "reason=design partner"]
               )

      assert {:ok, %{plan: "team"}} = Billing.support_plan(account)

      assert {:ok, %{subscriptions: subscriptions}} =
               Admin.execute("emisar.admin.analytics.revenue", [])

      assert %{plan: "team", status: "complimentary", accounts: 1} in subscriptions
    end

    test "groups terminal non-success outcomes without counting fan-out as operations" do
      account_one = Fixtures.Accounts.create_account()
      account_two = Fixtures.Accounts.create_account()
      runner_one = Fixtures.Runners.create_runner(account_id: account_one.id)
      runner_two = Fixtures.Runners.create_runner(account_id: account_two.id)
      pack_ref = "nomad@0.4.3/sha256:" <> String.duplicate("a", 64)

      shared = %{
        action_id: "nomad.job_health_snapshot",
        source: :mcp,
        status: :failed,
        pack_ref: pack_ref,
        client_info: %{"name" => "Claude Code"}
      }

      for {account, runner, operation_id} <- [
            {account_one, runner_one, "op_724NN9NMDZ1T76NARWCKM5A0D6"},
            {account_one, runner_one, "op_724NN9NMDZ1T76NARWCKM5A0D6"},
            {account_two, runner_two, "op_725NN9NMDZ1T76NARWCKM5A0D6"}
          ] do
        Fixtures.Runs.create_run(
          account_id: account.id,
          runner_id: runner.id,
          action_id: shared.action_id,
          source: shared.source,
          status: shared.status
        )
        |> update_run_analytics!(Map.put(shared, :operation_id, operation_id))
      end

      Fixtures.Runs.create_run(
        account_id: account_one.id,
        runner_id: runner_one.id,
        action_id: shared.action_id,
        source: :mcp,
        status: :denied
      )
      |> update_run_analytics!(%{
        operation_id: "op_726NN9NMDZ1T76NARWCKM5A0D6",
        pack_ref: pack_ref,
        client_info: %{"name" => "Claude Code"}
      })

      Fixtures.Runs.create_run(
        account_id: account_one.id,
        runner_id: runner_one.id,
        action_id: shared.action_id,
        source: :mcp,
        status: :success
      )
      |> update_run_analytics!(%{
        operation_id: "op_727NN9NMDZ1T76NARWCKM5A0D6",
        pack_ref: pack_ref,
        client_info: %{"name" => "Claude Code"}
      })

      assert {:ok, report} =
               Admin.execute("emisar.admin.runtime.recent_failures", ["days=1"])

      failed_group = Enum.find(report.groups, &(&1.status == :failed))
      denied_group = Enum.find(report.groups, &(&1.status == :denied))

      assert failed_group.action_id == "nomad.job_health_snapshot"
      assert failed_group.pack_ref == pack_ref
      assert failed_group.source == :mcp
      assert failed_group.client == "Claude Code"
      assert failed_group.run_count == 3
      assert failed_group.operation_count == 2
      assert failed_group.account_count == 2
      assert %DateTime{} = failed_group.last_seen_at

      assert denied_group.status == :denied
      assert denied_group.run_count == 1
      assert denied_group.operation_count == 1
      # Both halves of the response answer "what is failing?" with one status
      # set, so the denied run the groups count is in the recent sample too —
      # a group with no matching sample row reads as a broken sample. The
      # success is in neither.
      assert report.failures |> Enum.map(& &1.status) |> Enum.frequencies() ==
               %{failed: 3, denied: 1}

      assert %DateTime{} = report.since
    end
  end

  defp update_run_analytics!(run, attrs) do
    run
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp live_staff_session do
    {_raw, session} = Fixtures.Admin.create_staff_session(Fixtures.Admin.create_staff())
    session
  end

  # The code only leaves Admin by email, so a sign-in test reads it back out of
  # the delivered message, exactly as staff do.
  defp request_code(staff) do
    assert {:ok, %{token_id: token_id, nonce: nonce}} =
             Admin.request_staff_sign_in(staff.email, %RequestContext{})

    assert_received {:email, sent}
    {token_id, nonce, Fixtures.Auth.code_from_email(sent)}
  end

  defp sign_in(token_id, nonce, code, otp),
    do: Admin.complete_staff_sign_in(token_id, nonce, code, otp, %RequestContext{})

  defp other_code("ZZZZZZ"), do: "YYYYYY"
  defp other_code(_code), do: "ZZZZZZ"

  defp wrong_otp(staff) do
    case Fixtures.Admin.totp_code(staff) do
      "000000" -> "111111"
      _current -> "000000"
    end
  end
end
