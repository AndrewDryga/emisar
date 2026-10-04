defmodule Emisar.Admin do
  @moduledoc """
  Emisar staff operations: staff logins, the staff console's reads, and the
  private admin pack's release-RPC commands. None of it is a tenant's surface.

  A staff login (`Emisar.Admin.Staff`) is a realm of its own. Rows are created,
  reset and removed only by the `Emisar.Release` staff commands run on the
  production node; the web, MCP, the admin pack, SSO, SCIM, invitations and
  configuration have no path to one. Every sign-in needs the emailed split code
  and the current authenticator code, and yields a 12-hour session of its own
  (`Emisar.Admin.StaffToken`) that the web layer keeps in its own cookie.

  The staff-console reads — `search_accounts/2`, `account_overview/2`,
  `record_account_view/2` — back the web `/admin` LiveViews. Each takes the
  staff session as its last positional argument, in the seat a `%Subject{}`
  holds elsewhere: staff hold no membership in the accounts they inspect, so
  there is no subject to scope by, and `ensure_staff/1` re-reads that session
  before any row is read.

  `execute/2` is the private administrative command boundary invoked through
  release RPC. The public web and MCP routers never call it; the colocated
  private pack is the only caller, its arguments have already passed runner
  validation, and the action run is the authenticated audit record. Mutations
  use an actorless platform subject because the RPC carries no user credential.
  """
  alias Ecto.Multi
  alias Emisar.{Accounts, Audit, Auth, Billing, Crypto, Mailers}
  alias Emisar.Admin.{Query, Staff, StaffToken}
  alias Emisar.Auth.Subject
  alias Emisar.{Repo, RequestContext, Throttle}
  require Logger

  @arg_name ~r/^[a-z][a-z0-9_]*$/
  @job_modules [
    Emisar.Accounts.Jobs.MonthlyReports,
    Emisar.ApiKeys.Jobs.DeviceGrantCleanup,
    Emisar.Approvals.Jobs.ExpireOverdueRequests,
    Emisar.Audit.Jobs.Retention,
    Emisar.Auth.Jobs.TokenRetention,
    Emisar.Billing.Jobs.ProcessedEventRetention,
    Emisar.Billing.Jobs.SyncRunnerQuantities,
    Emisar.Billing.Jobs.SyncSubscriptions,
    Emisar.Catalog.Jobs.PackVersionRetention,
    Emisar.MCPOperations.Jobs.ReplayRetention,
    Emisar.OAuth.Jobs.Cleanup,
    Emisar.Runners.Jobs.InactiveRunnerRetention,
    Emisar.Runners.Jobs.InstallKeyRetention,
    Emisar.Runbooks.Jobs.AdvanceExecutions,
    Emisar.Runbooks.Jobs.ExecutionRetention,
    Emisar.Runs.Jobs.ActionRunRetention,
    Emisar.Runs.Jobs.DispatchTimeout,
    Emisar.Runs.Jobs.FleetObservability,
    Emisar.SSO.Jobs.AuthorizationReconcile
  ]

  @doc "Every supervised recurrent job, for runtime inspection and test hygiene."
  def job_modules, do: @job_modules

  # -- Staff logins ----------------------------------------------------

  @staff_sign_in_attempts 5
  @staff_sign_in_validity_seconds 15 * 60
  @staff_session_validity_seconds 12 * 60 * 60
  @staff_mfa_failure_limit 5

  @doc """
  Internal — `Emisar.Release.create_staff/1`, run on the production node, is the
  only caller. Creates the staff login for `email` with a fresh authenticator
  secret and returns that secret once: `{:ok, %Staff{}, secret}` or
  `{:error, %Ecto.Changeset{}}`.
  """
  def create_staff(email) when is_binary(email) do
    secret = Crypto.totp_secret()

    changeset = Staff.Changeset.create(email, secret)

    with {:ok, staff} <- Repo.insert(changeset) do
      Logger.info("staff login created staff_id=#{staff.id}")
      {:ok, staff, secret}
    end
  end

  @doc """
  Internal — `Emisar.Release.reset_staff/1` only. Gives the staff login for
  `email` a new authenticator secret, clears its failure count, and deletes
  every session and pending sign-in code it holds, disconnecting its open
  sockets: `{:ok, %Staff{}, secret}` or `{:error, :not_found}`.
  """
  def reset_staff(email) when is_binary(email) do
    secret = Crypto.totp_secret()

    Multi.new()
    |> Multi.run(:staff, fn repo, _changes -> lock_staff_by_email(repo, email) end)
    |> Multi.run(:digests, fn repo, %{staff: staff} -> delete_staff_tokens(repo, staff) end)
    |> Multi.update(:reset, fn %{staff: staff} -> Staff.Changeset.reset(staff, secret) end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{reset: staff, digests: digests}} ->
        :ok = disconnect_staff_sockets(digests)
        Logger.info("staff login reset staff_id=#{staff.id}")
        {:ok, staff, secret}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Internal — `Emisar.Release.remove_staff/1` only. Deletes the staff login for
  `email` with every session and pending sign-in code, disconnecting its open
  sockets: `:ok` or `{:error, :not_found}`.
  """
  def remove_staff(email) when is_binary(email) do
    Multi.new()
    |> Multi.run(:staff, fn repo, _changes -> lock_staff_by_email(repo, email) end)
    |> Multi.run(:digests, fn repo, %{staff: staff} -> delete_staff_tokens(repo, staff) end)
    |> Multi.delete(:removed, fn %{staff: staff} -> staff end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{removed: staff, digests: digests}} ->
        :ok = disconnect_staff_sockets(digests)
        Logger.info("staff login removed staff_id=#{staff.id}")
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "Internal — `Emisar.Release.list_staff/0` only. Every staff login, by email."
  def list_staff, do: Staff.Query.ordered_by_email() |> Repo.all()

  @doc """
  Whether wrong authenticator codes have locked `staff` until a box reset:
  #{@staff_mfa_failure_limit} in a row, each after a correct emailed code.
  """
  def staff_locked?(%Staff{failed_mfa_attempts: count}), do: count >= @staff_mfa_failure_limit

  defp lock_staff_by_email(repo, email) do
    email
    |> String.trim()
    |> Staff.Query.by_email()
    |> Staff.Query.lock_for_update()
    |> repo.fetch(Staff.Query)
  end

  # Every session and pending code of `staff`, deleted under its row lock. The
  # session digests come back so their sockets can be disconnected after commit.
  defp delete_staff_tokens(repo, %Staff{id: staff_id}) do
    {_count, digests} =
      StaffToken.Query.by_staff_id(staff_id)
      |> StaffToken.Query.by_context(:session)
      |> StaffToken.Query.select_token_digests()
      |> repo.delete_all()

    {_count, _rows} = staff_id |> StaffToken.Query.by_staff_id() |> repo.delete_all()
    {:ok, digests}
  end

  @doc """
  Internal — pre-auth: the first half of a staff sign-in, from the staff sign-in
  page. A staff login whose address is `email` gets a new sign-in code, bound to
  the requesting browser, and an email carrying it. Any other address gets a
  decoy: nothing is written or sent. Either way the result has the same shape,
  `{:ok, %{token_id: id, nonce: nonce}}`, and the caller keeps both in the
  requesting browser, because the code works only together with that nonce.

  Each login gets at most five codes per 15 minutes, whichever client addresses
  ask, so nobody can flood the staff inbox; a refused request is a decoy too,
  and is logged. Someone asking for codes in staff's name can hold back a new
  code until the window passes, but never cancels one already sent: a request
  leaves every other browser's pending code working. A completed sign-in
  cancels the login's other pending codes.
  """
  def request_staff_sign_in(email, %RequestContext{} = context) when is_binary(email) do
    {nonce, code, digest} = Crypto.magic_link_token()

    with %Staff{} = staff <- peek_staff_by_email(email),
         :ok <- check_staff_code_budget(staff, context) do
      issue_staff_sign_in(staff, nonce, code, digest, context)
    else
      _decoy -> {:ok, staff_sign_in_decoy(nonce)}
    end
  end

  # One budget per login, shared by every client address: a budget per address
  # let an address pool send the staff inbox as many codes as it had addresses.
  defp check_staff_code_budget(%Staff{} = staff, context) do
    with {:error, :rate_limited} = refused <-
           Throttle.check("staff_sign_in_code", staff.id, 5, 900_000) do
      Logger.warning(
        "staff sign-in code throttled staff_id=#{staff.id} ip=#{inspect(context.ip_address)}"
      )

      refused
    end
  end

  defp peek_staff_by_email(email) do
    email = String.trim(email)

    if email != "" and byte_size(email) <= 254,
      do: email |> Staff.Query.by_email() |> Repo.peek()
  end

  defp staff_sign_in_decoy(nonce), do: %{token_id: Repo.generate_id(), nonce: nonce}

  defp issue_staff_sign_in(%Staff{} = staff, nonce, code, digest, context) do
    expires_at = DateTime.add(DateTime.utc_now(), @staff_sign_in_validity_seconds, :second)

    Multi.new()
    |> Multi.delete_all(
      :expired,
      staff.id
      |> StaffToken.Query.by_staff_id()
      |> StaffToken.Query.by_context(:sign_in)
      |> StaffToken.Query.expired()
    )
    |> Multi.insert(
      :token,
      StaffToken.Changeset.sign_in(staff, digest, @staff_sign_in_attempts, expires_at)
    )
    |> Repo.commit_multi()
    |> case do
      {:ok, %{token: token}} ->
        Logger.info(
          "staff sign-in code issued staff_id=#{staff.id} ip=#{inspect(context.ip_address)}"
        )

        :ok = deliver_staff_sign_in_code(staff, code, context)
        {:ok, %{token_id: token.id, nonce: nonce}}

      {:error, _reason} ->
        {:ok, staff_sign_in_decoy(nonce)}
    end
  end

  defp deliver_staff_sign_in_code(staff, code, context) do
    case Mailers.UserNotifier.deliver_staff_sign_in_code(staff, code, context) do
      {:ok, _delivery} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "staff sign-in code not delivered staff_id=#{staff.id} " <>
            "reason=#{Mailers.UserNotifier.failure_label(reason)}"
        )
    end
  end

  @doc """
  Internal — pre-auth: the second half of a staff sign-in. Takes the `token_id`
  and `nonce` that `request_staff_sign_in/2` gave the browser, the emailed
  `code`, and the current authenticator code `otp`, all in one submission.

  Returns `{:ok, raw_session_token, %StaffToken{}}` (a 12-hour session with its
  staff preloaded; the raw token goes into the staff cookie and is stored
  nowhere), `{:error, :locked}` when the emailed code was right but wrong
  authenticator codes locked the login, or `{:error, :invalid}` otherwise.

  Every failed submission spends one of the code's #{@staff_sign_in_attempts}
  attempts. A wrong or reused authenticator code after a correct emailed code
  also counts against the login, and #{@staff_mfa_failure_limit} in a row lock
  it until `Emisar.Release.reset_staff/1`. Only someone holding the inbox and
  the requesting browser can reach that counter.
  """
  def complete_staff_sign_in(token_id, nonce, code, otp, %RequestContext{} = context)
      when is_binary(token_id) and is_binary(nonce) and is_binary(code) and is_binary(otp) do
    case peek_staff_sign_in(token_id) do
      %StaffToken{staff_id: staff_id} ->
        staff_id
        |> judge_staff_sign_in(token_id, nonce, normalize_sign_in_code(code), String.trim(otp))
        |> finish_staff_sign_in(staff_id, context)

      nil ->
        Logger.warning(
          "staff sign-in failed reason=unknown_code ip=#{inspect(context.ip_address)}"
        )

        {:error, :invalid}
    end
  end

  # The unlocked read only names the staff row to lock first; the transaction
  # re-reads and locks the code itself.
  defp peek_staff_sign_in(token_id) do
    if Repo.valid_uuid?(token_id) do
      token_id |> StaffToken.Query.by_id() |> StaffToken.Query.by_context(:sign_in) |> Repo.peek()
    end
  end

  # The typed code may carry spaces, dashes or lowercase letters; the alphabet
  # is uppercase.
  defp normalize_sign_in_code(code), do: code |> String.upcase() |> String.replace(~r/[\s-]/, "")

  # Lock order: the staff row, then its code. The row lock serializes every
  # sign-in of one login, so the failure count and the replay stamp are judged
  # on their current values, and the clock is read only once both are held.
  defp judge_staff_sign_in(staff_id, token_id, nonce, code, otp) do
    Multi.new()
    |> Multi.run(:staff, fn repo, _changes ->
      staff_id |> Staff.Query.by_id() |> Staff.Query.lock_for_update() |> repo.fetch(Staff.Query)
    end)
    |> Multi.run(:token, fn repo, %{staff: staff} ->
      StaffToken.Query.by_id(token_id)
      |> StaffToken.Query.by_staff_id(staff.id)
      |> StaffToken.Query.by_context(:sign_in)
      |> StaffToken.Query.lock_for_update()
      |> repo.fetch(StaffToken.Query)
    end)
    |> Multi.run(:outcome, fn repo, %{staff: staff, token: token} ->
      {:ok, staff_sign_in_outcome(repo, staff, token, nonce, code, otp)}
    end)
    |> Repo.commit_multi()
  end

  defp staff_sign_in_outcome(repo, %Staff{} = staff, %StaffToken{} = token, nonce, code, otp) do
    now = DateTime.utc_now()

    cond do
      DateTime.compare(token.expires_at, now) != :gt or token.remaining_attempts < 1 ->
        :expired_code

      not Crypto.secure_compare(Crypto.magic_link_digest(nonce, code), token.token) ->
        {:ok, _token} = repo.update(StaffToken.Changeset.spend_attempt(token))
        :invalid_code

      staff_locked?(staff) ->
        :locked

      not fresh_totp?(staff, otp, now) ->
        {:ok, _token} = repo.update(StaffToken.Changeset.spend_attempt(token))
        {:ok, failed} = repo.update(Staff.Changeset.mfa_failed(staff))

        if staff_locked?(failed), do: :locked, else: :invalid_otp

      true ->
        {:signed_in, start_staff_session(repo, staff, now)}
    end
  end

  # Valid at `now`, and from a newer 30-second bucket than the last code this
  # login signed in with, so an observed code cannot be used twice.
  defp fresh_totp?(%Staff{mfa_secret: secret, mfa_last_used_at: last_used}, otp, now) do
    Crypto.valid_totp?(secret, otp, now) and
      (is_nil(last_used) or totp_bucket(last_used) < totp_bucket(now))
  end

  defp totp_bucket(%DateTime{} = at), do: div(DateTime.to_unix(at), 30)

  defp start_staff_session(repo, staff, now) do
    {raw, digest} = Crypto.session_token()
    expires_at = DateTime.add(now, @staff_session_validity_seconds, :second)

    {:ok, staff} = repo.update(Staff.Changeset.signed_in(staff, now))

    # The code just used and every other pending one go; so do sessions that
    # have run out.
    {_count, _rows} =
      staff.id
      |> StaffToken.Query.by_staff_id()
      |> StaffToken.Query.by_context(:sign_in)
      |> repo.delete_all()

    {_count, _rows} =
      staff.id
      |> StaffToken.Query.by_staff_id()
      |> StaffToken.Query.by_context(:session)
      |> StaffToken.Query.expired()
      |> repo.delete_all()

    {:ok, session} = repo.insert(StaffToken.Changeset.session(staff, digest, expires_at))
    {raw, %{session | staff: staff}}
  end

  defp finish_staff_sign_in({:ok, %{outcome: {:signed_in, {raw, session}}}}, _staff_id, context) do
    Logger.info(
      "staff sign-in succeeded staff_id=#{session.staff_id} ip=#{inspect(context.ip_address)}"
    )

    {:ok, raw, session}
  end

  defp finish_staff_sign_in({:ok, %{outcome: reason}}, staff_id, context) do
    Logger.warning(
      "staff sign-in failed reason=#{reason} staff_id=#{staff_id} ip=#{inspect(context.ip_address)}"
    )

    if reason == :locked, do: {:error, :locked}, else: {:error, :invalid}
  end

  # The login or its code vanished between the unlocked read and the locks: a
  # box reset or removal, or a sign-in that completed with another code.
  defp finish_staff_sign_in({:error, _reason}, staff_id, context) do
    Logger.warning(
      "staff sign-in failed reason=code_gone staff_id=#{staff_id} ip=#{inspect(context.ip_address)}"
    )

    {:error, :invalid}
  end

  @doc """
  Internal — staff session plumbing. The live session behind a raw staff cookie
  token, with its staff preloaded: `{:ok, %StaffToken{}}`, or
  `{:error, :not_found}` when it is unknown, expired, signed out, or its login
  was reset or removed.
  """
  def fetch_staff_session(raw) when is_binary(raw) do
    raw
    |> Crypto.hash()
    |> StaffToken.Query.by_token_digest()
    |> StaffToken.Query.by_context(:session)
    |> StaffToken.Query.not_expired()
    |> StaffToken.Query.with_preloaded_staff()
    |> Repo.fetch(StaffToken.Query)
  end

  @doc """
  Internal — staff session plumbing. Re-reads a session the caller already
  holds, for the console reads below and the LiveView hooks that re-check it on
  every event; same returns as `fetch_staff_session/1`.
  """
  def refresh_staff_session(%StaffToken{context: :session, id: id}) when is_binary(id) do
    if Repo.valid_uuid?(id) do
      StaffToken.Query.by_id(id)
      |> StaffToken.Query.by_context(:session)
      |> StaffToken.Query.not_expired()
      |> StaffToken.Query.with_preloaded_staff()
      |> Repo.fetch(StaffToken.Query)
    else
      {:error, :not_found}
    end
  end

  def refresh_staff_session(_session), do: {:error, :not_found}

  @doc "Internal — staff sign-out: deletes the session behind a raw staff cookie token."
  def delete_staff_session(raw) when is_binary(raw) do
    {_count, staff_ids} =
      raw
      |> Crypto.hash()
      |> StaffToken.Query.by_token_digest()
      |> StaffToken.Query.by_context(:session)
      |> StaffToken.Query.select_staff_ids()
      |> Repo.delete_all()

    # Cloud Logging is the only staff record, so a session the browser ended is
    # written down like the sign-in that started it.
    Enum.each(staff_ids, &Logger.info("staff signed out staff_id=#{&1}"))
    :ok
  end

  @doc """
  Internal — the LiveView socket id for the session behind a raw staff cookie
  token. It is derived from the stored digest, so a box reset or removal can
  name the same topic from the database, without the cookie.
  """
  def staff_session_socket_topic(raw) when is_binary(raw),
    do: raw |> Crypto.hash() |> staff_socket_topic()

  defp staff_socket_topic(digest), do: "staff_sessions:" <> Crypto.encode_digest(digest)

  defp disconnect_staff_sockets([]), do: :ok

  defp disconnect_staff_sockets(digests) do
    topics = Enum.map(digests, &staff_socket_topic/1)

    case Emisar.Config.get_env(:emisar, :session_disconnect_handler) do
      {application, handler} when is_atom(application) and is_atom(handler) ->
        if application_started?(application), do: handler.disconnect_live_sessions(topics)

      _missing_or_invalid ->
        :ok
    end

    :ok
  end

  defp application_started?(application),
    do: List.keymember?(Application.started_applications(), application, 0)

  # -- Staff console reads ---------------------------------------------

  @doc """
  Accounts matching `query_string` — `{:ok, [%Accounts.Account{}]}`, or
  `{:error, :unauthorized}` when the staff session is no longer live.

  Matches account name, account slug, and member email, capped at 25. A blank
  query lists the 20 most recently created accounts instead. Disabled accounts
  are included: staff see the whole platform, and a disabled account is the one
  its owner can no longer open a support case from.
  """
  # IL-3 has no shape for this path: staff hold no membership in the accounts
  # they search, so there is no `%Subject{}` to gate with and no query for
  # `Authorizer.for_subject/2` to narrow — `ensure_staff/1`, run before the
  # read, IS the boundary. Nor is it an `@doc "Internal"` helper: this is the
  # staff console's public API. The moduledoc declares the whole module.
  # credo:disable-for-next-line Emisar.Checks.ContextPublicFnSubject
  def search_accounts(query_string, %StaffToken{} = staff_session)
      when is_binary(query_string) do
    with {:ok, _session} <- ensure_staff(staff_session) do
      accounts = query_string |> String.trim() |> search_queryable() |> Repo.all()
      {:ok, accounts}
    end
  end

  defp search_queryable(""), do: Query.recent_accounts()
  defp search_queryable(term), do: Query.accounts_matching(term)

  @doc """
  One account's whole support picture — `{:ok, overview}`, `{:error,
  :not_found}`, or `{:error, :unauthorized}` when the staff session is no
  longer live. The account is found by id or slug, disabled ones included.

  The overview is a map of sections, each carrying whole structs: `:account`,
  `:billing` (`Billing.support_plan/1`), `:members` (every Member, suspended
  and unaccepted invitations included), `:sso` (identity
  providers — an account may hold one per kind), `:fleet` (`:counts` by
  connection state plus up to 50 `:runners`, most recently connected first),
  `:runs` (`:count_30d` and the 10 most recent), `:mcp` (`:active_api_keys`
  and the 30-day `:recent_clients` tally), and `:audit_tail` (the 10 most
  recent audit events).

  `:runs.recent` carries `%Runs.ActionRun{}` structs, so those rows hold the
  customer's argument and output payloads. The console renders run identity,
  status, and timing — never a payload field.
  """
  def account_overview(id_or_slug, %StaffToken{} = staff_session) when is_binary(id_or_slug) do
    with {:ok, _session} <- ensure_staff(staff_session),
         reference = String.trim(id_or_slug),
         {:ok, account} <- Accounts.fetch_account_by_id_or_slug_including_disabled(reference),
         {:ok, billing} <- Billing.support_plan(account) do
      {:ok, overview_sections(account, billing)}
    end
  end

  defp overview_sections(%Accounts.Account{} = account, billing) do
    since = DateTime.add(DateTime.utc_now(), -30, :day)

    %{
      account: account,
      billing: billing,
      members: Query.account_memberships(account.id) |> Repo.all(),
      sso: Query.account_identity_providers(account.id) |> Repo.all(),
      fleet: %{
        counts: Query.account_runner_connection_counts(account.id) |> Repo.one(),
        runners: Query.recent_account_runners(account.id) |> Repo.all()
      },
      runs: %{
        count_30d: aggregate_count(Query.account_runs_since(account.id, since)),
        recent: Query.recent_account_runs(account.id) |> Repo.all()
      },
      mcp: %{
        active_api_keys: Query.active_api_key_count(account.id) |> Repo.one(),
        recent_clients: Query.account_mcp_clients_since(account.id, since) |> Repo.all()
      },
      audit_tail: Query.recent_audit_events(account.id) |> Repo.all()
    }
  end

  @doc """
  Append the staff console's view of `account` to that account's own audit
  trail — `{:ok, %Audit.Event{}}`, `{:error, %Ecto.Changeset{}}` if the row is
  rejected, or `{:error, :unauthorized}` when the staff session is no longer
  live. The customer seeing this row is the point; see
  `Audit.Events.staff_account_viewed/2`. Which staff login looked is kept in
  Emisar's own logs, never in the customer's trail.
  """
  def record_account_view(%Accounts.Account{} = account, %StaffToken{} = staff_session) do
    with {:ok, session} <- ensure_staff(staff_session),
         {:ok, event} <- Audit.record(Audit.Events.staff_account_viewed(session.staff, account)) do
      Logger.info("staff viewed account staff_id=#{session.staff_id} account_id=#{account.id}")
      {:ok, event}
    end
  end

  # The staff console reads ACROSS tenants, so there is no query to narrow the
  # way `Authorizer.for_subject/2` does — this gate is the whole boundary, and it
  # runs before any row is read rather than filtering one afterwards.
  #
  # The verdict is the DATABASE row, never the caller's struct. A connected
  # LiveView holds the session it mounted with for the life of its socket, so
  # judging that snapshot would let an open console keep reading every tenant
  # after a sign-out, a box reset or removal, or the session's expiry. One
  # indexed primary-key read per staff call buys a current answer.
  defp ensure_staff(%StaffToken{} = staff_session) do
    case refresh_staff_session(staff_session) do
      {:ok, session} -> {:ok, session}
      {:error, :not_found} -> {:error, :unauthorized}
    end
  end

  # -- Private pack RPC ------------------------------------------------

  @doc "Execute one action from the trusted, colocated private admin pack."
  def execute("emisar.admin." <> _ = action_id, encoded_args)
      when is_list(encoded_args) and length(encoded_args) <= 4 do
    with {:ok, args} <- decode_args(encoded_args) do
      dispatch(action_id, args)
    end
  end

  def execute(_action_id, _encoded_args), do: {:error, :invalid_admin_request}

  defp decode_args(encoded_args) do
    Enum.reduce_while(encoded_args, {:ok, %{}}, fn encoded, {:ok, args} ->
      case String.split(encoded, "=", parts: 2) do
        [name, value] ->
          if Regex.match?(@arg_name, name) and not Map.has_key?(args, name),
            do: {:cont, {:ok, Map.put(args, name, value)}},
            else: {:halt, {:error, :invalid_admin_arguments}}

        _ ->
          {:halt, {:error, :invalid_admin_arguments}}
      end
    end)
  end

  defp dispatch("emisar.admin.account.find", %{"query" => term}) do
    accounts = term |> String.trim() |> Query.accounts_matching() |> Repo.all()
    {:ok, %{accounts: Enum.map(accounts, &account_result/1)}}
  end

  defp dispatch("emisar.admin.account.show", args) do
    with {:ok, account} <- fetch_account(args),
         {:ok, plan} <- Billing.support_plan(account),
         {:ok, _event} <- Audit.record(Audit.Events.staff_account_viewed_by_support(account)) do
      result = account |> account_result() |> Map.put(:billing, plan)
      {:ok, result}
    end
  end

  defp dispatch(
         "emisar.admin.account.create",
         %{"email" => email, "name" => name, "slug" => slug}
       ) do
    case Accounts.fetch_account_by_id_or_slug_including_disabled(slug) do
      {:ok, account} ->
        {:ok, Map.put(account_result(account), :created, false)}

      {:error, :not_found} ->
        with {:ok, %{account: account}} <-
               Accounts.create_account_with_invited_owner(
                 %{name: name, slug: slug},
                 String.trim(email),
                 inviter()
               ) do
          {:ok, account |> account_result() |> Map.put(:created, true)}
        end
    end
  end

  defp dispatch(
         "emisar.admin.support.set_slack_channel",
         %{"url" => url, "reason" => reason} = args
       ) do
    with true <-
           (String.trim(reason) != "" and byte_size(reason) <= 500) ||
             {:error, :invalid_reason},
         {:ok, account} <- fetch_account(args),
         {:ok, account} <- Accounts.put_support_slack_url(account.id, url) do
      {:ok, account_result(account)}
    end
  end

  defp dispatch(
         "emisar.admin.plan.grant",
         %{"plan" => plan, "reason" => _reason} = args
       ) do
    with {:ok, account} <- fetch_account(args),
         {:ok, _subscription} <- Billing.grant_complimentary_plan(account, plan) do
      Billing.support_plan(account)
    end
  end

  defp dispatch(
         "emisar.admin.plan.revoke",
         %{"reason" => _reason} = args
       ) do
    with {:ok, account} <- fetch_account(args),
         {:ok, _subscription} <- Billing.revoke_complimentary_plan(account) do
      Billing.support_plan(account)
    end
  end

  defp dispatch(
         "emisar.admin.account.disable",
         %{"reason" => reason} = args
       ),
       do: set_account_disabled(args, true, reason)

  defp dispatch(
         "emisar.admin.account.enable",
         %{"reason" => reason} = args
       ),
       do: set_account_disabled(args, false, reason)

  defp dispatch(
         "emisar.admin.access.diagnose",
         %{"member" => member} = args
       ) do
    with {:ok, account} <- fetch_account(args),
         {:ok, membership} <- fetch_membership(account.id, member),
         {:ok, _event} <- Audit.record(Audit.Events.staff_account_viewed_by_support(account)) do
      {:ok,
       %{
         account: account_result(account),
         member: membership_result(membership),
         email_verified: not is_nil(membership.email_verified_at),
         mfa_enabled: not is_nil(membership.mfa_enabled_at),
         active_sessions: membership |> Query.member_session_count() |> Repo.one(),
         active_api_keys: Query.active_api_key_count(account.id, membership.id) |> Repo.one()
       }}
    end
  end

  defp dispatch(
         "emisar.admin.invitation.resend",
         %{"member" => member} = args
       ) do
    with {:ok, account} <- fetch_account(args),
         {:ok, membership} <- fetch_membership(account.id, member),
         target_subject = support_subject(account),
         {:ok, result} <-
           Accounts.resend_account_invitation_and_deliver(membership, inviter(), target_subject) do
      {:ok, membership_result(result.membership)}
    end
  end

  defp dispatch(
         "emisar.admin.member.invite",
         %{"email" => email, "role" => role} = args
       ) do
    with {:ok, account} <- fetch_account(args),
         target_subject = support_subject(account),
         {:ok, result} <-
           Accounts.invite_user_to_account_and_deliver(
             %{"email" => email, "role" => role, "runner_access_mode" => "all"},
             inviter(),
             target_subject
           ) do
      {:ok, membership_result(result.membership)}
    end
  end

  defp dispatch("emisar.admin.member.suspend", args),
    do: mutate_member(args, &Accounts.suspend_membership/2)

  defp dispatch("emisar.admin.member.reinstate", args),
    do: mutate_member(args, &Accounts.reinstate_membership/2)

  defp dispatch(
         "emisar.admin.member.set_role",
         %{"role" => role} = args
       ) do
    mutate_member(args, &set_member_role(&1, role, &2, args["runner_access"]))
  end

  defp dispatch("emisar.admin.sessions.revoke", args),
    do: mutate_member(args, &Accounts.end_all_sessions_for/2)

  defp dispatch("emisar.admin.mfa.reset", args),
    do: mutate_member(args, &Accounts.reset_member_mfa_for_support/2)

  defp dispatch(
         "emisar.admin.owner.transfer",
         %{"new_owner" => new_owner} = args
       ) do
    with {:ok, account} <- fetch_account(args),
         target_subject = support_subject(account),
         {:ok, next_owner} <- fetch_membership(account.id, new_owner),
         {:ok, demotion} <- owner_demotion_plan(account, args),
         {:ok, promoted} <- Accounts.update_membership_role(next_owner, "owner", target_subject),
         :ok <- maybe_demote_previous_owner(demotion, target_subject) do
      {:ok, membership_result(promoted)}
    end
  end

  defp dispatch("emisar.admin.billing.sync", args) do
    with {:ok, account} <- fetch_account(args),
         {:ok, _subscription} <- Billing.sync_subscription_for_support(account) do
      Billing.support_plan(account)
    end
  end

  defp dispatch("emisar.admin.analytics.executive", args),
    do: analytics_executive(args)

  defp dispatch("emisar.admin.analytics.revenue", _args) do
    {:ok, %{subscriptions: Query.subscription_posture() |> Repo.all()}}
  end

  defp dispatch("emisar.admin.analytics.engagement", args),
    do: analytics_engagement(args)

  defp dispatch("emisar.admin.analytics.reliability", args),
    do: analytics_reliability(args)

  defp dispatch("emisar.admin.analytics.mcp", args),
    do: analytics_mcp(args)

  defp dispatch("emisar.admin.analytics.security", args),
    do: analytics_security(args)

  defp dispatch("emisar.admin.analytics.data_quality", _args) do
    {:ok, %{row_counts: Query.table_counts() |> Repo.one()}}
  end

  defp dispatch("emisar.admin.runtime.status", _args) do
    {:ok,
     %{
       node: Atom.to_string(node()),
       release: Application.spec(:emisar, :vsn) |> to_string(),
       system_time: DateTime.utc_now(),
       schedulers_online: :erlang.system_info(:schedulers_online),
       process_count: :erlang.system_info(:process_count)
     }}
  end

  defp dispatch("emisar.admin.runtime.jobs", _args) do
    jobs =
      Enum.map(@job_modules, fn module ->
        pid = :global.whereis_name({Emisar.Jobs.Executors.GloballyUnique, module})
        %{job: inspect(module), leader: is_pid(pid), leader_node: job_node(pid)}
      end)

    {:ok, %{jobs: jobs}}
  end

  defp dispatch("emisar.admin.runtime.database", _args) do
    started = System.monotonic_time()

    case Ecto.Adapters.SQL.query(Repo, "SELECT current_database(), pg_is_in_recovery()", []) do
      {:ok, %{rows: [[database, replica?]]}} ->
        duration =
          System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

        {:ok, %{database: database, replica: replica?, latency_ms: duration}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch("emisar.admin.runtime.recent_failures", args) do
    since = since(args)

    {:ok,
     %{
       since: since,
       groups: Query.non_success_outcome_groups_since(since) |> Repo.all(),
       failures: Query.recent_failures(since, 50) |> Repo.all()
     }}
  end

  defp dispatch(
         "emisar.admin.account.erase",
         %{"account_id" => account_id, "confirmation" => confirmation, "reason" => _reason}
       )
       when account_id == confirmation do
    with {:ok, account} <- Accounts.delete_by_id(account_id) do
      {:ok, %{erased_account_id: account.id}}
    end
  end

  defp dispatch(
         "emisar.admin.member.erase",
         %{"member" => member, "confirmation" => confirmation, "reason" => _reason} = args
       )
       when member == confirmation do
    with {:ok, account_id} <- erasure_account_id(args),
         {:ok, %{membership: membership, account: erased_account}} <-
           Accounts.erase_member(account_id, member) do
      # A sole Member's workspace goes with it; say so rather than leave the
      # operator to discover the workspace is gone.
      {:ok, %{erased_member_id: membership.id, erased_account_id: erased_account && account_id}}
    end
  end

  defp dispatch(action_id, _args),
    do: {:error, {:unsupported_admin_action, action_id}}

  defp set_account_disabled(args, disabled?, reason) do
    with {:ok, account} <- fetch_account(args),
         target_subject = support_subject(account),
         {:ok, account} <-
           Accounts.set_account_disabled_for_support(
             account.id,
             disabled?,
             reason,
             target_subject
           ) do
      {:ok, account_result(account)}
    end
  end

  defp mutate_member(%{"member" => member} = args, mutation) do
    with {:ok, account} <- fetch_account(args),
         {:ok, membership} <- fetch_membership(account.id, member) do
      membership
      |> mutation.(support_subject(account))
      |> normalize_member_mutation(membership)
    end
  end

  # A mutation returns the row it wrote, or `:ok` when it wrote none of its own.
  defp normalize_member_mutation({:ok, %Accounts.Membership{} = membership}, _fetched),
    do: {:ok, membership_result(membership)}

  defp normalize_member_mutation(:ok, membership), do: {:ok, membership_result(membership)}
  defp normalize_member_mutation({:error, reason}, _membership), do: {:error, reason}

  defp set_member_role(membership, "directory", subject, _access),
    do: Accounts.return_owner_to_directory(membership, subject)

  defp set_member_role(%Accounts.Membership{role: :owner} = membership, role, subject, selection)
       when role != "owner" do
    with {:ok, access} <- owner_demotion_access(membership, selection) do
      Accounts.update_membership_role(membership, role, subject,
        runner_access: access,
        expected_role: :owner
      )
    end
  end

  defp set_member_role(membership, role, subject, _selection),
    do: Accounts.update_membership_role(membership, role, subject)

  defp owner_demotion_plan(account, args) do
    case args["previous_owner"] do
      ref when ref in [nil, ""] ->
        {:ok, nil}

      ref ->
        with {:ok, membership} <- fetch_membership(account.id, ref),
             {:ok, access} <- owner_demotion_access(membership, args["previous_owner_access"]) do
          {:ok, {membership, access}}
        end
    end
  end

  defp owner_demotion_access(
         %Accounts.Membership{role: :owner, runner_access_directory_managed: true},
         "directory"
       ),
       do: {:ok, :directory}

  defp owner_demotion_access(
         %Accounts.Membership{role: :owner, runner_access_directory_managed: true},
         _selection
       ),
       do: {:error, :owner_demotion_requires_directory}

  defp owner_demotion_access(%Accounts.Membership{role: :owner}, "all"),
    do: {:ok, Accounts.RunnerAccess.all()}

  defp owner_demotion_access(%Accounts.Membership{role: :owner}, "none"),
    do: {:ok, Accounts.RunnerAccess.none()}

  defp owner_demotion_access(_membership, _selection),
    do: {:error, :owner_demotion_requires_access}

  defp maybe_demote_previous_owner(nil, _subject), do: :ok

  defp maybe_demote_previous_owner({membership, :directory}, subject) do
    with {:ok, _membership} <- Accounts.return_owner_to_directory(membership, subject), do: :ok
  end

  defp maybe_demote_previous_owner({membership, access}, subject) do
    with {:ok, _membership} <-
           Accounts.update_membership_role(membership, "admin", subject,
             runner_access: access,
             expected_role: :owner
           ) do
      :ok
    end
  end

  defp fetch_account(%{"account" => ref}) when is_binary(ref),
    do: Accounts.fetch_account_by_id_or_slug_including_disabled(String.trim(ref))

  defp fetch_account(_), do: {:error, :account_required}

  # A closed workspace (tombstoned, not yet purged) still holds its Members, so
  # its exact UUID reaches it; a slug resolves only a live workspace.
  defp erasure_account_id(%{"account" => ref} = args) when is_binary(ref) do
    ref = String.trim(ref)

    if Repo.valid_uuid?(ref) do
      {:ok, ref}
    else
      with {:ok, account} <- fetch_account(args), do: {:ok, account.id}
    end
  end

  defp erasure_account_id(_args), do: {:error, :account_required}

  defp fetch_membership(account_id, ref) when is_binary(ref) do
    queryable =
      if Repo.valid_uuid?(ref),
        do: Query.membership_by_id(account_id, ref),
        else: Query.membership_by_email(account_id, String.trim(ref))

    Repo.fetch(queryable, Accounts.Membership.Query)
  end

  # Platform support work has no user credential at this RPC boundary. The
  # authenticated action run records who dispatched it; domain audit records it
  # as system work.
  defp support_subject(account) do
    %Subject{
      account: account,
      role: :owner,
      permissions: Auth.Permissions.for_role(:owner)
    }
  end

  defp account_result(account) do
    %{
      id: account.id,
      name: account.name,
      slug: account.slug,
      disabled: not is_nil(account.disabled_at),
      support_slack_url: account.settings.support_slack_url,
      created_at: account.inserted_at
    }
  end

  defp membership_result(membership) do
    %{
      id: membership.id,
      email: membership.email,
      role: membership.role,
      disabled: not is_nil(membership.disabled_at),
      invitation_pending: Accounts.membership_invitation_pending?(membership)
    }
  end

  defp inviter, do: %{full_name: "Emisar Support", email: "support@emisar.dev"}

  defp analytics_executive(args) do
    since = since(args)
    statuses = Query.run_statuses_since(since) |> Repo.all()

    {:ok,
     %{
       since: since,
       accounts_created: aggregate_count(Query.count_accounts_since(since)),
       memberships_created: aggregate_count(Query.count_memberships_since(since)),
       runners_created: aggregate_count(Query.count_runners_since(since)),
       runs: aggregate_count(Query.count_runs_since(since)),
       run_statuses: statuses
     }}
  end

  defp analytics_engagement(args) do
    since = since(args)

    {:ok, %{since: since, active_accounts: Query.active_account_ids_since(since) |> Repo.all()}}
  end

  defp analytics_reliability(args) do
    since = since(args)

    {:ok,
     %{
       since: since,
       statuses: Query.run_statuses_since(since) |> Repo.all(),
       top_actions: Query.top_actions_since(since) |> Repo.all()
     }}
  end

  defp analytics_mcp(args) do
    since = since(args)
    {:ok, %{since: since, clients: Query.mcp_clients_since(since) |> Repo.all()}}
  end

  defp analytics_security(args) do
    since = since(args)
    {:ok, %{since: since, approvals: Query.approval_statuses_since(since) |> Repo.all()}}
  end

  defp aggregate_count(queryable), do: Repo.aggregate(queryable, :count, :id)

  defp since(%{"days" => days}) when is_binary(days) do
    case Integer.parse(days) do
      {days, ""} when days in 1..3650 -> DateTime.add(DateTime.utc_now(), -days, :day)
      _ -> DateTime.add(DateTime.utc_now(), -30, :day)
    end
  end

  defp since(_), do: DateTime.add(DateTime.utc_now(), -30, :day)

  defp job_node(pid) when is_pid(pid), do: pid |> node() |> Atom.to_string()
  defp job_node(_), do: nil
end
