defmodule Emisar.Audit.Events do
  @moduledoc """
  Per-event audit-row builders for Accounts mutations. Each returns an
  `Ecto.Changeset` for `Ecto.Multi.insert/3` (or `Repo.insert/1` inside a
  plain transaction), so the caller passes the domain structs plus the
  acting `%Subject{}` and never has to know the audit field schema —
  `actor_kind` / `actor_id` / `subject_kind` / `subject_id` / `payload`
  are this module's concern, not the context's.
  """
  alias Emisar.Accounts.{Account, Membership, User}
  alias Emisar.Audit
  alias Emisar.Auth.Subject

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

  def membership_role_changed(%Subject{} = subject, %Membership{} = target, new_role) do
    Audit.changeset(
      target.account_id,
      "membership.role_changed",
      actor(subject) ++
        [
          subject_kind: "user",
          subject_id: target.user_id,
          payload: %{from: target.role, to: new_role}
        ]
    )
  end

  def membership_suspended(%Subject{} = subject, %Membership{} = target),
    do: member_event(subject, target, "membership.suspended")

  def membership_reinstated(%Subject{} = subject, %Membership{} = target),
    do: member_event(subject, target, "membership.reinstated")

  def membership_removed(%Subject{} = subject, %Membership{} = target) do
    Audit.changeset(
      target.account_id,
      "membership.removed",
      actor(subject) ++
        [subject_kind: "user", subject_id: target.user_id, payload: %{role: target.role}]
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

  def user_password_reset_forced(%Subject{} = subject, %Membership{} = target, %User{} = user),
    do: user_event(subject, target, user, "user.password_reset_forced")

  def user_sessions_revoked(%Subject{} = subject, %Membership{} = target, %User{} = user),
    do: user_event(subject, target, user, "user.sessions_revoked")

  def user_updated_by_admin(%Subject{} = subject, %Membership{} = target, %User{} = user) do
    Audit.changeset(
      target.account_id,
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

  # -- Internals -------------------------------------------------------

  defp member_event(%Subject{} = subject, %Membership{} = target, event_type) do
    Audit.changeset(
      target.account_id,
      event_type,
      actor(subject) ++ [subject_kind: "user", subject_id: target.user_id]
    )
  end

  defp user_event(%Subject{} = subject, %Membership{} = target, %User{} = user, event_type) do
    Audit.changeset(
      target.account_id,
      event_type,
      actor(subject) ++ [subject_kind: "user", subject_id: user.id, subject_label: user.email]
    )
  end

  defp actor(%Subject{} = subject),
    do: [actor_kind: Subject.actor_kind(subject), actor_id: Subject.actor_id(subject)]
end
