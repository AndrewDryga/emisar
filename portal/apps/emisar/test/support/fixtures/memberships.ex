defmodule Emisar.Fixtures.Memberships do
  @moduledoc """
  Membership test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Memberships.create_membership/1`. A Member is the only person
  record: its email, its sign-in and its MFA factor are its own.
  """

  alias Emisar.Accounts.{Membership, MembershipRunnerScope, RunnerAccess}
  alias Emisar.Auth.Subject
  alias Emisar.{Fixtures, Repo}

  @passthrough_fields [
    :invited_by_membership_id,
    :invitation_token_digest,
    :invitation_accepted_at,
    :directory_managed,
    :runner_access_directory_managed,
    :directory_provider_id,
    :directory_authorization_pending_version
  ]

  @mfa_state_fields [:mfa_secret, :mfa_enabled_at, :mfa_recovery_codes, :mfa_last_used_at]

  @doc """
  Creates a workspace Member. `:account_id` defaults to a new account, `:email`
  to a unique address (pass `email: nil` for a Member that has none),
  `:display_name` to "Test User", `:role` to operator and `:runner_access_mode`
  to all. The address counts as proved (`email_verified_at`) unless
  `email_verified?: false` or the Member is a pending invitee, whose address is
  proved only by accepting.
  """
  def create_membership(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || Fixtures.Accounts.create_account().id

    params =
      %{
        account_id: account_id,
        display_name: Map.get(attrs, :display_name, "Test User"),
        email: Map.get(attrs, :email, Fixtures.Random.unique_email()),
        role: attrs[:role] || "operator",
        runner_access_mode: attrs[:runner_access_mode] || "all"
      }
      |> Map.merge(Map.take(attrs, @passthrough_fields))

    pending_invitee? =
      is_binary(params[:invitation_token_digest]) and is_nil(params[:invitation_accepted_at])

    verified? = Map.get(attrs, :email_verified?, not pending_invitee?)

    params
    |> Membership.Changeset.create()
    |> then(fn changeset ->
      if verified? and is_binary(params.email),
        do: Ecto.Changeset.put_change(changeset, :email_verified_at, DateTime.utc_now()),
        else: changeset
    end)
    |> Repo.insert!()
  end

  @doc """
  Creates a service account: the Member an app connects as. `:account_id`
  defaults to a new account and `:display_name` to "Ryker"; it reaches every
  runner and pack unless `:runner_access` names another `%RunnerAccess{}`.
  """
  def create_service_account(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || Fixtures.Accounts.create_account().id
    access = Map.get(attrs, :runner_access, RunnerAccess.all())
    profile = %{display_name: Map.get(attrs, :display_name, "Ryker")}

    account_id
    |> Membership.Changeset.create_service_account(profile, access)
    |> Repo.insert!()
    |> force_runner_access(access)
  end

  @doc """
  Test-only role override. Production code MUST go through
  `Accounts.update_membership_role/3` with a `%Subject{}`. This bypasses
  the last-owner / self-promotion / role-hierarchy guards, which exist
  to protect humans — fine to ignore in fixtures that rig a state
  directly.
  """
  def force_role(%Membership{} = membership, role) when is_binary(role) do
    {:ok, updated} =
      membership
      |> Membership.Changeset.update(%{role: role})
      |> Repo.update()

    if updated.role == :owner do
      force_runner_access(updated, RunnerAccess.all())
    else
      updated
    end
  end

  @doc """
  Test-only runner-access override. Production code MUST go through
  `Accounts.update_membership_runner_access/3`; this helper rigs an existing
  caller's state without exercising nondelegation or emitting an audit event.
  """
  def force_runner_access(%Membership{} = membership, %RunnerAccess{} = access) do
    {:ok, updated} = Repo.transact(fn -> do_force_runner_access(membership, access) end)
    updated
  end

  defp do_force_runner_access(membership, access) do
    membership = Repo.reload!(membership)
    access = RunnerAccess.for_role(membership.role, access)

    {:ok, _result} =
      Ecto.Adapters.SQL.query(
        Repo,
        "SELECT set_config('emisar.runner_access_write', 'enabled', true)",
        []
      )

    {:ok, updated} =
      membership
      |> Membership.Changeset.update_runner_access(access)
      |> Repo.update()

    MembershipRunnerScope.Query.by_membership_id(membership.id)
    |> Repo.delete_all()

    now = DateTime.utc_now()

    rows =
      Enum.map(RunnerAccess.scope_tuples(access), fn {scope_type, scope_value} ->
        %{
          id: Repo.generate_id(),
          membership_id: membership.id,
          scope_type: scope_type,
          scope_value: scope_value,
          inserted_at: now
        }
      end)

    Repo.insert_all(MembershipRunnerScope, rows)

    {:ok, _result} =
      Ecto.Adapters.SQL.query(
        Repo,
        "SELECT set_config('emisar.runner_access_write', 'disabled', true)",
        []
      )

    {:ok, updated}
  end

  @doc "Marks a membership's directory authorization as pending without running reconciliation."
  def mark_directory_authorization_pending(%Membership{} = membership, version) do
    membership
    |> Ecto.Changeset.change(directory_authorization_pending_version: version)
    |> Repo.update!()
  end

  @doc "Suspends a membership (sets `disabled_at`) directly, returning the updated struct."
  def suspend_membership(%Membership{} = membership) do
    {:ok, suspended} =
      membership
      |> Membership.Changeset.suspend(nil)
      |> Repo.update()

    suspended
  end

  @doc "Permanently removes an owned fixture Member to exercise attribution FK behavior."
  def hard_delete_membership(%Membership{} = membership), do: Repo.delete!(membership)

  @doc "Soft-deletes a membership, returning the tombstoned row."
  def mark_membership_as_deleted(%Membership{} = membership) do
    {:ok, deleted} =
      membership
      |> Membership.Changeset.delete()
      |> Repo.update()

    deleted
  end

  @doc """
  Moves a Member to another address directly. No flow changes a Member's email
  any more (invite the new address instead), so this only arranges the stale
  state an in-flight code or proof must refuse.
  """
  def change_email(%Membership{} = membership, email) when is_binary(email) do
    membership
    |> Ecto.Changeset.change(email: email)
    |> Repo.update!()
  end

  @doc "Sets a membership's coarse console-activity timestamp directly."
  def set_last_active_at(%Membership{} = membership, %DateTime{} = last_active_at) do
    {:ok, updated} =
      membership
      |> Ecto.Changeset.change(last_active_at: last_active_at)
      |> Repo.update()

    updated
  end

  @doc "Marks a membership directory-managed (the SCIM synced-role lock), as a sync would."
  def mark_directory_managed(%Membership{} = membership) do
    {:ok, managed} =
      membership
      |> Membership.Changeset.sync_role(membership.role)
      |> Repo.update()

    managed
  end

  @doc "Sets the display name the directory supplied for this member."
  def sync_display_name(%Membership{} = membership, display_name) do
    {:ok, named} =
      membership
      |> Membership.Changeset.sync_display_name(display_name)
      |> Repo.update()

    named
  end

  @doc """
  Test inspector: the normalized `{scope_type, scope_value}` rows behind a
  membership's runner access. `Accounts` collapses an inconsistent row set to
  `none()` on read, so reading the effective access can't tell a rewritten row
  set from a stale one — a test that must prove the ROWS moved reads them here.
  """
  def list_runner_scopes(%Membership{} = membership) do
    MembershipRunnerScope.Query.by_membership_id(membership.id)
    |> MembershipRunnerScope.Query.ordered_by_type_and_value()
    |> Repo.all()
    |> Enum.map(&{&1.scope_type, &1.scope_value})
  end

  @doc "Rigs a Member's stored MFA state directly for tests that exercise later lifecycle transitions."
  def set_mfa_state(%Membership{} = membership, attrs) do
    attrs = Map.new(attrs)

    case Map.keys(attrs) -- @mfa_state_fields do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown MFA state fields: #{inspect(Enum.sort(unknown))}"
    end

    membership
    |> Ecto.Changeset.change(Map.take(attrs, @mfa_state_fields))
    |> Repo.update!()
  end

  @doc """
  Enrolls TOTP MFA through the real current-inbox proof and returns its tagged
  result (`{:ok, membership, recovery_codes}` / `{:error, reason}`). The
  enrollment completes on a disposable session of the same Member, deleted
  afterwards, so `subject`'s own session keeps its proof state; pass
  `session_token:` (a raw token of the Member) to complete on that session
  instead. A test asserting `enable_mfa`'s success contract calls this
  directly; `enable_mfa!/3` wraps it for setup.
  """
  def enroll_mfa(secret, %Subject{actor: %Membership{} = membership} = subject, opts \\ [])
      when is_binary(secret) do
    {session_token, disposable_session?} =
      case Keyword.fetch(opts, :session_token) do
        {:ok, token} ->
          {token, false}

        :error ->
          token =
            Fixtures.Auth.create_session_token!(
              membership,
              subject.auth_method || :magic_link,
              nil,
              %{},
              user_identity_id: subject.user_identity_id
            )

          {token, true}
      end

    try do
      subject =
        Fixtures.Subjects.subject_for(membership,
          session: session_token,
          context: subject.context
        )

      proof = mfa_enrollment_proof(subject)

      Emisar.Auth.enable_mfa(
        secret,
        Fixtures.Auth.totp_code(secret),
        proof,
        Emisar.Crypto.hash(session_token),
        subject
      )
    after
      if disposable_session?, do: Fixtures.Auth.delete_session_token!(session_token)
    end
  end

  @doc "Issues and verifies the real current-inbox proof used by MFA enrollment tests."
  def mfa_enrollment_proof(%Subject{} = subject) do
    {:ok, :sent} = Emisar.Auth.issue_mfa_enrollment_code(subject)

    email =
      receive do
        {:email, email} -> email
      after
        1_000 -> raise "MFA enrollment code email was not delivered"
      end

    code = Fixtures.Auth.code_from_email(email)
    {:ok, proof} = Emisar.Auth.verify_mfa_enrollment_code(code, subject)
    proof
  end

  @doc """
  Enrolls MFA as test setup, unwrapping `enroll_mfa/3` to `{membership,
  recovery_codes}`. Enrollment spends the code that proved it, so setup leaves
  the factor enrolled one 30-second step ago: a test can answer a challenge
  with the current code straight away.
  """
  def enable_mfa!(secret, %Subject{} = subject, opts \\ []) when is_binary(secret) do
    {:ok, membership, codes} = enroll_mfa(secret, subject, opts)
    {enrolled_a_step_ago(membership), codes}
  end

  @doc """
  Moves a fresh enrollment's replay stamp one 30-second step back, as if the
  factor were enrolled a step ago, so a test can answer with the current code.
  """
  def enrolled_a_step_ago(%Membership{mfa_last_used_at: %DateTime{} = stamped} = membership),
    do: set_mfa_state(membership, mfa_last_used_at: DateTime.add(stamped, -30, :second))
end
