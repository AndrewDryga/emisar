defmodule Emisar.Audit.Events do
  @moduledoc """
  Per-event audit-row builders for domain mutations. Each returns an
  `Ecto.Changeset` for `Ecto.Multi.insert/3` (or `Repo.insert/1` inside a
  plain transaction), so the caller passes the domain structs plus the
  acting `%Subject{}` and never has to know the audit field schema —
  `actor_kind` / `actor_id` / `subject_kind` / `subject_id` / `payload`
  are this module's concern, not the context's. Fire-and-forget standalone
  events (no `Multi`, often no subject) use `Audit.log/3` directly instead.
  """
  alias Emisar.Accounts.{Account, Membership}
  alias Emisar.{ApiKeys, Approvals, Runbooks, Runners}
  alias Emisar.Audit
  alias Emisar.Auth.Subject
  alias Emisar.Users.User

  # -- Account ---------------------------------------------------------

  def account_created(%Account{} = account, %User{} = owner) do
    Audit.changeset(account.id, "account.created",
      actor_kind: "user",
      actor_id: owner.id,
      subject_kind: "account",
      subject_id: account.id,
      subject_label: account.name,
      payload: %{plan: account.plan, slug: account.slug}
    )
  end

  def user_signed_up(%User{} = user, %Account{} = account) do
    Audit.changeset(account.id, "user.signed_up",
      actor_kind: "user",
      actor_id: user.id,
      subject_kind: "user",
      subject_id: user.id,
      subject_label: user.email
    )
  end

  def account_updated(%Subject{} = subject, %Account{} = account) do
    Audit.changeset(
      account.id,
      "account.updated",
      actor(subject) ++
        [
          subject_kind: "account",
          subject_id: account.id,
          subject_label: account.name,
          payload: %{name: account.name, slug: account.slug}
        ]
    )
  end

  def account_require_mfa_set(%Subject{} = subject, %Account{} = account) do
    Audit.changeset(
      account.id,
      "account.require_mfa_set",
      actor(subject) ++
        [
          subject_kind: "account",
          subject_id: account.id,
          payload: %{require_mfa: account.require_mfa}
        ]
    )
  end

  # -- Membership ------------------------------------------------------

  def membership_role_changed(%Subject{} = subject, %Membership{} = membership, new_role) do
    Audit.changeset(
      membership.account_id,
      "membership.role_changed",
      actor(subject) ++
        [
          subject_kind: "user",
          subject_id: membership.user_id,
          payload: %{from: membership.role, to: new_role}
        ]
    )
  end

  def membership_suspended(%Subject{} = subject, %Membership{} = membership),
    do: member_event(subject, membership, "membership.suspended")

  def membership_reinstated(%Subject{} = subject, %Membership{} = membership),
    do: member_event(subject, membership, "membership.reinstated")

  def membership_removed(%Subject{} = subject, %Membership{} = membership) do
    Audit.changeset(
      membership.account_id,
      "membership.removed",
      actor(subject) ++
        [subject_kind: "user", subject_id: membership.user_id, payload: %{role: membership.role}]
    )
  end

  def membership_runner_scopes_changed(%Subject{} = subject, %Membership{} = membership, scopes)
      when is_list(scopes) do
    Audit.changeset(
      membership.account_id,
      "membership.runner_scopes_changed",
      actor(subject) ++
        [
          subject_kind: "user",
          subject_id: membership.user_id,
          payload: %{
            scope_count: length(scopes),
            scopes: Enum.map(scopes, fn {type, value} -> %{type: type, value: value} end)
          }
        ]
    )
  end

  # Self-service (no Subject): switching tenants is the user acting on
  # their own session; the membership identifies both actor and subject.
  def session_account_switched(%Membership{user: %User{} = user} = membership) do
    Audit.changeset(membership.account_id, "session.account_switched",
      actor_kind: "user",
      actor_id: membership.user_id,
      subject_kind: "user",
      subject_id: membership.user_id,
      subject_label: user.email,
      payload: %{role: membership.role}
    )
  end

  # Self-service accept (no Subject): the membership's own user is both
  # the actor and the subject.
  def membership_invitation_accepted(%Membership{} = membership) do
    Audit.changeset(membership.account_id, "membership.invitation_accepted",
      actor_kind: "user",
      actor_id: membership.user_id,
      subject_kind: "user",
      subject_id: membership.user_id,
      payload: %{role: membership.role}
    )
  end

  # -- User ------------------------------------------------------------

  def user_password_reset_forced(
        %Subject{} = subject,
        %Membership{} = membership,
        %User{} = user
      ),
      do: user_event(subject, membership, user, "user.password_reset_forced")

  def user_sessions_revoked(%Subject{} = subject, %Membership{} = membership, %User{} = user),
    do: user_event(subject, membership, user, "user.sessions_revoked")

  def user_updated_by_admin(%Subject{} = subject, %Membership{} = membership, %User{} = user) do
    Audit.changeset(
      membership.account_id,
      "user.updated_by_admin",
      actor(subject) ++
        [
          subject_kind: "user",
          subject_id: user.id,
          subject_label: user.email,
          payload: %{full_name: user.full_name}
        ]
    )
  end

  def user_invited(%Subject{} = subject, %User{} = invited, role) do
    Audit.changeset(
      subject.account.id,
      "user.invited",
      actor(subject) ++
        [
          subject_kind: "user",
          subject_id: invited.id,
          subject_label: invited.email,
          payload: %{role: role}
        ]
    )
  end

  # Self-service accept (no Subject): the user accepting is the actor.
  def user_invitation_accepted(%User{} = user, %Membership{} = membership) do
    Audit.changeset(membership.account_id, "user.invitation_accepted",
      actor_kind: "user",
      actor_id: user.id,
      subject_kind: "user",
      subject_id: user.id,
      subject_label: user.email,
      payload: %{role: membership.role}
    )
  end

  # -- Runner ----------------------------------------------------------

  def runner_disabled(%Subject{} = subject, %Runners.Runner{} = runner),
    do: runner_event(subject, runner, "runner.disabled")

  def runner_enabled(%Subject{} = subject, %Runners.Runner{} = runner),
    do: runner_event(subject, runner, "runner.enabled")

  def runner_deleted(%Subject{} = subject, %Runners.Runner{} = runner),
    do: runner_event(subject, runner, "runner.deleted")

  # -- Auth keys (runner install/enrolment keys) -----------------------

  def auth_key_created(%Subject{} = subject, %Runners.AuthKey{} = key) do
    Audit.changeset(
      key.account_id,
      "auth_key.created",
      actor(subject) ++
        [
          subject_kind: "auth_key",
          subject_id: key.id,
          payload: %{prefix: key.key_prefix, reusable: key.reusable, group: key.group}
        ]
    )
  end

  def auth_key_revoked(%Subject{} = subject, %Runners.AuthKey{} = key) do
    Audit.changeset(
      key.account_id,
      "auth_key.revoked",
      actor(subject) ++
        [subject_kind: "auth_key", subject_id: key.id, payload: %{prefix: key.key_prefix}]
    )
  end

  # -- API keys --------------------------------------------------------

  def api_key_created(%Subject{} = subject, %ApiKeys.ApiKey{} = key) do
    Audit.changeset(
      key.account_id,
      "api_key.created",
      actor(subject) ++
        [
          subject_kind: "api_key",
          subject_id: key.id,
          subject_label: key.name,
          payload: %{prefix: key.key_prefix, scopes: key.scopes}
        ]
    )
  end

  def api_key_revoked(%Subject{} = subject, %ApiKeys.ApiKey{} = key) do
    Audit.changeset(
      key.account_id,
      "api_key.revoked",
      actor(subject) ++
        [
          subject_kind: "api_key",
          subject_id: key.id,
          subject_label: key.name,
          payload: %{prefix: key.key_prefix}
        ]
    )
  end

  # Auto-bind during OAuth/MCP issuance — no user is acting, so the actor
  # is the system rather than a `%Subject{}`.
  def api_key_bound(%ApiKeys.ApiKey{} = key) do
    Audit.changeset(key.account_id, "api_key.bound",
      actor_kind: "system",
      subject_kind: "api_key",
      subject_id: key.id,
      subject_label: key.name,
      payload: %{prefix: key.key_prefix, auto: true}
    )
  end

  # -- Runbooks --------------------------------------------------------

  def runbook_created(%Subject{} = subject, %Runbooks.Runbook{} = runbook) do
    runbook_event(subject, runbook, "runbook.created", %{
      name: runbook.name,
      title: runbook.title,
      version: runbook.version
    })
  end

  def runbook_updated(
        %Subject{} = subject,
        %Runbooks.Runbook{} = old,
        %Runbooks.Runbook{} = runbook
      ) do
    runbook_event(subject, runbook, "runbook.updated", %{
      name: runbook.name,
      title: runbook.title,
      from_version: old.version,
      to_version: runbook.version
    })
  end

  def runbook_published(%Subject{} = subject, %Runbooks.Runbook{} = runbook) do
    runbook_event(subject, runbook, "runbook.published", %{
      name: runbook.name,
      version: runbook.version
    })
  end

  # -- Approval grants -------------------------------------------------

  def approval_grant_revoked(%Subject{} = subject, %Approvals.Grant{} = grant) do
    Audit.changeset(
      grant.account_id,
      "approval.grant_revoked",
      actor(subject) ++
        [
          subject_kind: "approval_grant",
          subject_id: grant.id,
          payload: %{action_id: grant.action_id, api_key_id: grant.api_key_id}
        ]
    )
  end

  # -- Internals -------------------------------------------------------

  defp runner_event(%Subject{} = subject, %Runners.Runner{} = runner, event_type) do
    Audit.changeset(
      runner.account_id,
      event_type,
      actor(subject) ++
        [subject_kind: "runner", subject_id: runner.id, subject_label: runner.name]
    )
  end

  defp runbook_event(%Subject{} = subject, %Runbooks.Runbook{} = runbook, event_type, payload) do
    Audit.changeset(
      runbook.account_id,
      event_type,
      actor(subject) ++
        [
          subject_kind: "runbook",
          subject_id: runbook.id,
          subject_label: runbook.title || runbook.name,
          payload: payload
        ]
    )
  end

  defp member_event(%Subject{} = subject, %Membership{} = membership, event_type) do
    Audit.changeset(
      membership.account_id,
      event_type,
      actor(subject) ++ [subject_kind: "user", subject_id: membership.user_id]
    )
  end

  defp user_event(%Subject{} = subject, %Membership{} = membership, %User{} = user, event_type) do
    Audit.changeset(
      membership.account_id,
      event_type,
      actor(subject) ++ [subject_kind: "user", subject_id: user.id, subject_label: user.email]
    )
  end

  defp actor(%Subject{} = subject),
    do: [actor_kind: Subject.actor_kind(subject), actor_id: Subject.actor_id(subject)]
end
