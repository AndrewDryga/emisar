defmodule Emisar.Audit.Events do
  @moduledoc """
  Per-event audit-row builders for domain mutations. Each returns an
  `Ecto.Changeset` for `Ecto.Multi.insert/3` (or `Repo.insert/1` inside a
  plain transaction), so the caller passes the domain structs plus the
  acting `%Subject{}` and never has to know the audit field schema —
  `actor_kind` / `actor_id` / `subject_kind` / `subject_id` / `payload`
  are this module's concern, not the context's. A fire-and-forget
  standalone event (no `Multi` to join — a runner socket connect, a
  dispatch-time policy decision) still goes through a builder here,
  inserted with `Audit.record/1`; only an event with no fixed
  actor/subject shape falls back to raw `Audit.log/3`.
  """
  alias Emisar.{Accounts, ApiKeys, Approvals, Catalog, OAuth, Policies}
  alias Emisar.Audit
  alias Emisar.Auth.Subject
  alias Emisar.RequestContext
  alias Emisar.{Runbooks, Runners, Runs, SSO, Users}

  # -- Account ---------------------------------------------------------

  def account_created(%Accounts.Account{} = account, %Users.User{} = owner) do
    Audit.changeset(account.id, "account.created",
      actor_kind: "user",
      actor_id: owner.id,
      subject_kind: "account",
      subject_id: account.id,
      subject_label: account.name,
      # A brand-new account has no subscription yet, so it is always on the
      # free plan at creation — recorded literally to avoid a cross-context
      # Billing call from the audit layer.
      payload: %{plan: "free", slug: account.slug}
    )
  end

  def user_signed_up(%Users.User{} = user, %Accounts.Account{} = account) do
    Audit.changeset(account.id, "user.signed_up",
      actor_kind: "user",
      actor_id: user.id,
      subject_kind: "user",
      subject_id: user.id,
      subject_label: user.email
    )
  end

  def account_updated(%Subject{} = subject, %Accounts.Account{} = account) do
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

  def account_require_mfa_set(%Subject{} = subject, %Accounts.Account{} = account) do
    Audit.changeset(
      account.id,
      "account.require_mfa_set",
      actor(subject) ++
        [
          subject_kind: "account",
          subject_id: account.id,
          payload: %{require_mfa: account.settings.require_mfa}
        ]
    )
  end

  def account_require_sso_set(%Subject{} = subject, %Accounts.Account{} = account) do
    Audit.changeset(
      account.id,
      "account.require_sso_set",
      actor(subject) ++
        [
          subject_kind: "account",
          subject_id: account.id,
          payload: %{require_sso: account.settings.require_sso}
        ]
    )
  end

  def account_max_grant_lifetime_set(%Subject{} = subject, %Accounts.Account{} = account) do
    Audit.changeset(
      account.id,
      "account.max_grant_lifetime_set",
      actor(subject) ++
        [
          subject_kind: "account",
          subject_id: account.id,
          payload: %{max_grant_lifetime_seconds: account.settings.max_grant_lifetime_seconds}
        ]
    )
  end

  # -- Membership ------------------------------------------------------

  def membership_role_changed(%Subject{} = subject, %Accounts.Membership{} = membership, new_role) do
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

  def membership_suspended(%Subject{} = subject, %Accounts.Membership{} = membership),
    do: member_event(subject, membership, "membership.suspended")

  def membership_reinstated(%Subject{} = subject, %Accounts.Membership{} = membership),
    do: member_event(subject, membership, "membership.reinstated")

  def membership_removed(%Subject{} = subject, %Accounts.Membership{} = membership) do
    Audit.changeset(
      membership.account_id,
      "membership.removed",
      actor(subject) ++
        [subject_kind: "user", subject_id: membership.user_id, payload: %{role: membership.role}]
    )
  end

  def membership_runner_scopes_changed(
        %Subject{} = subject,
        %Accounts.Membership{} = membership,
        scopes
      )
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
  def session_account_switched(%Accounts.Membership{user: %Users.User{} = user} = membership) do
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
  def membership_invitation_accepted(%Accounts.Membership{} = membership) do
    Audit.changeset(membership.account_id, "membership.invitation_accepted",
      actor_kind: "user",
      actor_id: membership.user_id,
      subject_kind: "user",
      subject_id: membership.user_id,
      payload: %{role: membership.role}
    )
  end

  # -- User ------------------------------------------------------------

  def user_sessions_revoked(
        %Subject{} = subject,
        %Accounts.Membership{} = membership,
        %Users.User{} = user
      ),
      do: user_event(subject, membership, user, "user.sessions_revoked")

  def user_mfa_reset_by_admin(
        %Subject{} = subject,
        %Accounts.Membership{} = membership,
        %Users.User{} = user
      ),
      do: user_event(subject, membership, user, "user.mfa_reset_by_admin")

  def user_updated_by_admin(
        %Subject{} = subject,
        %Accounts.Membership{} = membership,
        %Users.User{} = user
      ) do
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

  def user_invited(%Subject{} = subject, %Users.User{} = invited, role) do
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
  def user_invitation_accepted(%Users.User{} = user, %Accounts.Membership{} = membership) do
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

  # Connection-lifecycle events fired by the runner socket process. The
  # runner itself is the actor — there is no acting `%Subject{}` — so the
  # actor/subject fields point at the runner row.
  def runner_connected(%Runners.Runner{} = runner, token_id, context \\ %RequestContext{}) do
    Audit.changeset(runner.account_id, "runner.connected",
      actor_kind: "runner",
      actor_id: runner.id,
      actor_label: runner.name,
      subject_kind: "runner",
      subject_id: runner.id,
      subject_label: runner.name,
      context: context,
      payload: %{token_id: token_id}
    )
  end

  def runner_disconnected(account_id, runner_id, reason, context \\ %RequestContext{}) do
    Audit.changeset(account_id, "runner.disconnected",
      actor_kind: "runner",
      actor_id: runner_id,
      subject_kind: "runner",
      subject_id: runner_id,
      context: context,
      payload: %{reason: reason}
    )
  end

  def runner_error(account_id, runner_id, %{} = payload, context \\ %RequestContext{}) do
    Audit.changeset(account_id, "runner.error",
      actor_kind: "runner",
      actor_id: runner_id,
      subject_kind: "runner",
      subject_id: runner_id,
      context: context,
      payload: payload
    )
  end

  # A runner enrolling itself via an auth key on first connect — the
  # runner is the actor, no operator `%Subject{}` is involved.
  def runner_registered(
        %Runners.Runner{} = runner,
        %Runners.AuthKey{} = key,
        context \\ %RequestContext{}
      ) do
    Audit.changeset(runner.account_id, "runner.registered",
      context: context,
      actor_kind: "runner",
      actor_id: runner.id,
      actor_label: runner.name,
      subject_kind: "runner",
      subject_id: runner.id,
      subject_label: runner.name,
      payload: %{
        external_id: runner.external_id,
        group: runner.group,
        hostname: runner.hostname,
        auth_key_id: key.id
      }
    )
  end

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
          payload: %{prefix: key.key_prefix, reusable: key.reusable}
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

  # Auto-generated install key promoted to permanent when a runner first
  # binds with it — system actor (no user is acting), mirroring api_key_bound.
  def auth_key_bound(%Runners.AuthKey{} = key) do
    Audit.changeset(key.account_id, "auth_key.bound",
      actor_kind: "system",
      subject_kind: "auth_key",
      subject_id: key.id,
      payload: %{prefix: key.key_prefix, auto: true}
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

  # -- OAuth -------------------------------------------------------------

  # Operator consent minted an execute-capable backing key for a remote
  # MCP client — the grant moment of the OAuth flow ("X gave Claude.ai
  # execute access"). Later token exchange/refresh is mechanical and
  # deliberately unaudited (per-hour noise; the standing capability is
  # what operators review).
  #
  # Explicit @spec (this module otherwise relies on struct-matched heads): it
  # gives the 1.20 set-theoretic checker the contract so it stops inferring the
  # `client` param shape from field access in the body — that inference is
  # incremental-compile-order-sensitive and flapped a false "incompatible types".
  @spec oauth_consent_granted(Subject.t(), OAuth.Client.t(), ApiKeys.ApiKey.t()) ::
          Ecto.Changeset.t()
  def oauth_consent_granted(
        %Subject{} = subject,
        %OAuth.Client{} = client,
        %ApiKeys.ApiKey{} = key
      ) do
    Audit.changeset(
      key.account_id,
      "oauth.consent_granted",
      actor(subject) ++
        [
          subject_kind: "api_key",
          subject_id: key.id,
          subject_label: key.name,
          payload: %{client_id: client.id, client_name: client.client_name, scopes: key.scopes}
        ]
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

  # A wave-engine dispatch that produced no run row (runner offline, a
  # row-less error) — the engine continuation has no acting subject, so
  # the actor is the system.
  def runbook_step_dispatch_failed(
        %Runbooks.Runbook{} = runbook,
        execution_id,
        step_id,
        runner_id,
        reason
      ) do
    Audit.changeset(runbook.account_id, "runbook.step_dispatch_failed",
      actor_kind: "system",
      subject_kind: "runbook",
      subject_id: runbook.id,
      subject_label: runbook.title,
      payload: %{
        runbook_id: runbook.id,
        runbook_execution_id: execution_id,
        runbook_step_id: step_id,
        runner_id: runner_id,
        reason: inspect(reason)
      }
    )
  end

  # -- Catalog pack trust ----------------------------------------------

  @doc """
  Operator adopted a pending pack hash. Takes the PRE-trust row so the
  payload can show what flipped (`previous_hash` → `new_hash`).
  """
  def pack_trust_adopted(%Subject{} = subject, %Catalog.PackVersion{} = pack_version) do
    pack_trust_event(subject, pack_version, "pack_trust_adopted", %{
      pack_id: pack_version.pack_id,
      version: pack_version.version,
      previous_hash: pack_version.hash,
      new_hash: pack_version.pending_hash
    })
  end

  @doc """
  Operator rejected a pending pack hash. Takes the PRE-reject row;
  `row_deleted: true` marks the never-trusted custom pack whose row is
  dropped entirely (nothing to fall back to).
  """
  def pack_trust_rejected(%Subject{} = subject, %Catalog.PackVersion{} = pack_version) do
    payload = %{
      pack_id: pack_version.pack_id,
      version: pack_version.version,
      trusted_hash: pack_version.hash,
      rejected_hash: pack_version.pending_hash
    }

    pack_trust_event(subject, pack_version, "pack_trust_rejected", payload)
  end

  defp pack_trust_event(
         %Subject{} = subject,
         %Catalog.PackVersion{} = pack_version,
         type,
         payload
       ) do
    Audit.changeset(
      pack_version.account_id,
      type,
      actor(subject) ++
        [
          subject_kind: "pack_version",
          subject_id: pack_version.id,
          subject_label: "#{pack_version.pack_id}@#{pack_version.version}",
          payload: payload
        ]
    )
  end

  # System-actor pack pins observed during a runner_state sync (no operator
  # is acting). pack_pinned/4 covers all three first-sight outcomes — the
  # `event_type` atom distinguishes baseline-match / mismatch / review.
  def pack_pinned(%Catalog.PackVersion{} = pack_version, event_type, advertised, baseline) do
    Audit.changeset(pack_version.account_id, event_type,
      actor_kind: "system",
      subject_kind: "pack_version",
      subject_id: pack_version.id,
      subject_label: "#{pack_version.pack_id}@#{pack_version.version}",
      payload: %{
        pack_id: pack_version.pack_id,
        version: pack_version.version,
        trusted_hash: pack_version.hash,
        pending_hash: pack_version.pending_hash,
        advertised: advertised,
        baseline: baseline
      }
    )
  end

  # A runner advertised bytes that diverge from the trusted hash — keep
  # trusted, record the new pending. System actor.
  def pack_trust_drift_detected(%Catalog.PackVersion{} = pack_version, advertised) do
    Audit.changeset(pack_version.account_id, "pack_trust_drift_detected",
      actor_kind: "system",
      subject_kind: "pack_version",
      subject_id: pack_version.id,
      subject_label: "#{pack_version.pack_id}@#{pack_version.version}",
      payload: %{
        pack_id: pack_version.pack_id,
        version: pack_version.version,
        trusted_hash: pack_version.hash,
        previous_pending: pack_version.pending_hash,
        pending_hash: advertised
      }
    )
  end

  # -- Policies --------------------------------------------------------

  def policy_updated(
        %Subject{} = subject,
        %Policies.Policy{} = old,
        %Policies.Policy{} = updated
      ) do
    before_rules = old.rules || Policies.default_rules()
    after_rules = updated.rules || Policies.default_rules()

    Audit.changeset(
      updated.account_id,
      "policy.updated",
      actor(subject) ++
        [
          subject_kind: "policy",
          subject_id: updated.id,
          payload: %{
            scope_type: to_string(updated.scope_type),
            scope_value: updated.scope_value,
            before: before_rules,
            after: after_rules,
            from_version: old.vsn,
            to_version: updated.vsn,
            changes: Policies.diff_rules(before_rules, after_rules)
          }
        ]
    )
  end

  @doc "A runner/group policy override was removed — that scope falls back to the account default."
  def policy_scope_deleted(%Subject{} = subject, %Policies.Policy{} = policy) do
    Audit.changeset(
      policy.account_id,
      "policy.scope_deleted",
      actor(subject) ++
        [
          subject_kind: "policy",
          subject_id: policy.id,
          payload: %{
            scope_type: to_string(policy.scope_type),
            scope_value: policy.scope_value,
            rules: policy.rules
          }
        ]
    )
  end

  # -- Approval decisions ----------------------------------------------

  # Emitted for EVERY vote (including a sub-threshold approve), so the
  # security log shows each operator's decision and the finalizing release
  # (approval.approved / approval.denied) as separate rows. `count` is the
  # distinct-approver tally after this vote (nil for a deny).
  def approval_decision_recorded(
        %Subject{} = subject,
        %Approvals.Request{} = request,
        decision,
        reason,
        count
      ) do
    Audit.changeset(
      request.account_id,
      "approval.decision_recorded",
      actor(subject) ++
        [
          subject_kind: "approval_request",
          subject_id: request.id,
          payload: %{
            run_id: request.run_id,
            decision: decision,
            reason: reason,
            approved_count: count,
            min_approvals: request.min_approvals
          }
        ]
    )
  end

  def approval_approved(
        %Subject{} = subject,
        %Approvals.Request{} = request,
        reason,
        grant,
        grant_attrs
      ) do
    Audit.changeset(
      request.account_id,
      "approval.approved",
      actor(subject) ++
        [
          subject_kind: "approval_request",
          subject_id: request.id,
          payload: %{
            run_id: request.run_id,
            reason: reason,
            grant_id: grant && grant.id,
            grant_duration: grant && grant_attrs.duration,
            grant_scope: grant && grant_attrs.scope
          }
        ]
    )
  end

  def approval_denied(%Subject{} = subject, %Approvals.Request{} = request, reason) do
    Audit.changeset(
      request.account_id,
      "approval.denied",
      actor(subject) ++
        [
          subject_kind: "approval_request",
          subject_id: request.id,
          payload: %{run_id: request.run_id, reason: reason}
        ]
    )
  end

  # Auto-rejected by the ApprovalExpiry sweep when no operator decided in
  # time — system actor, no acting subject.
  def approval_expired(%Approvals.Request{} = request) do
    Audit.changeset(request.account_id, "approval.expired",
      actor_kind: "system",
      subject_kind: "approval_request",
      subject_id: request.id,
      payload: %{run_id: request.run_id, expires_at: request.expires_at}
    )
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

  # -- Runs (dispatch decisions, cancel) -------------------------------

  # Dispatch refused because the action's pack hash diverges from what an
  # operator trusted — system actor (the trust gate runs inside an
  # already-authorized dispatch, with no acting subject).
  def dispatch_blocked_pack_untrusted(
        account_id,
        %{id: pv_id, pack_id: pack_id, version: version},
        action
      ) do
    Audit.changeset(account_id, "dispatch_blocked_pack_untrusted",
      actor_kind: "system",
      subject_kind: "pack_version",
      subject_id: pv_id,
      subject_label: "#{pack_id}@#{version}",
      payload: %{
        pack_id: pack_id,
        version: version,
        action_id: action.action_id,
        runner_id: action.runner_id
      }
    )
  end

  # No pin row exists for a versioned pack — dispatch failed CLOSED. Derived
  # from the action (no PackVersion struct to key the subject on).
  def dispatch_blocked_pack_untrusted(account_id, :no_pin, action) do
    Audit.changeset(account_id, "dispatch_blocked_pack_untrusted",
      actor_kind: "system",
      subject_kind: "pack_version",
      subject_label: "#{action.pack_id}@#{action.pack_version}",
      payload: %{
        pack_id: action.pack_id,
        version: action.pack_version,
        action_id: action.action_id,
        runner_id: action.runner_id
      }
    )
  end

  # Dispatch refused because the target runner advertises that it enforces
  # client signatures, so the portal won't send its own (operator/runbook)
  # unsigned run to it — only a signed MCP call gets through. System actor (the
  # gate runs inside an already-authorized dispatch, with no acting subject).
  def dispatch_blocked_requires_attestation(account_id, runner_id, action_id) do
    Audit.changeset(account_id, "dispatch_blocked_requires_attestation",
      actor_kind: "system",
      subject_kind: "runner",
      subject_id: runner_id,
      payload: %{action_id: action_id}
    )
  end

  def run_cancel_requested(%Subject{} = subject, %Runs.ActionRun{} = run, reason) do
    Audit.changeset(
      run.account_id,
      "run.cancel_requested",
      actor(subject) ++
        [
          # "action_run" — the canonical run subject_kind (every other run event +
          # the audit ref_path use it); "run" here dropped cancel-requests out of a
          # run's filtered audit trail.
          subject_kind: "action_run",
          subject_id: run.id,
          payload: %{from_status: run.status, reason: reason}
        ]
    )
  end

  # A run that bypassed approval via a standing grant — the grant + its
  # originating approval ride in the payload so operators can trace why it
  # fired without prompting. System actor.
  def grant_used(%Runs.ActionRun{} = run, grant, policy) do
    Audit.changeset(run.account_id, "approval.grant_used",
      actor_kind: "system",
      subject_kind: "action_run",
      subject_id: run.id,
      subject_label: run.action_id,
      payload: %{
        run_id: run.id,
        grant_id: grant.id,
        approval_request_id: grant.approval_request_id,
        policy_id: policy && policy.id,
        uses_count: grant.uses_count + 1,
        max_uses: grant.max_uses
      }
    )
  end

  # -- SSO -------------------------------------------------------------

  @doc "A user JIT-provisioned by an SSO login. Actor is the system (the IdP via JIT), not a member."
  def user_provisioned_via_sso(%Users.User{} = user, %SSO.IdentityProvider{} = provider) do
    Audit.changeset(provider.account_id, "user.provisioned_via_sso",
      actor_kind: "system",
      subject_kind: "user",
      subject_id: user.id,
      subject_label: user.email || user.full_name,
      payload: %{
        provider_id: provider.id,
        provider_kind: to_string(provider.kind),
        role: to_string(provider.default_role)
      }
    )
  end

  # -- Directory sync (SCIM) -------------------------------------------
  # IdP-pushed membership changes are their own actor class: the actor is
  # the directory connection (`directory_sync` + the provider id), so an
  # operator auditing an offboarding sees *which* directory did it, not a
  # generic "system" (decision 7).

  @doc "A user provisioned by inbound SCIM. Actor is the directory-sync connection, not a member."
  def user_provisioned_via_scim(%Users.User{} = user, %SSO.IdentityProvider{} = provider) do
    Audit.changeset(provider.account_id, "user.provisioned_via_scim",
      actor_kind: "directory_sync",
      actor_id: provider.id,
      actor_label: provider.name,
      subject_kind: "user",
      subject_id: user.id,
      subject_label: user.email || user.full_name,
      payload: %{
        provider_id: provider.id,
        provider_kind: to_string(provider.kind),
        role: to_string(provider.default_role)
      }
    )
  end

  @doc "A membership suspended by an inbound SCIM deprovision (`active:false`/DELETE)."
  def membership_deprovisioned_via_scim(
        %Accounts.Membership{} = membership,
        %SSO.IdentityProvider{} = provider
      ) do
    directory_sync_membership_event(membership, provider, "membership.deprovisioned_via_scim")
  end

  @doc "A suspended membership reinstated by an inbound SCIM `active:true`."
  def membership_reprovisioned_via_scim(
        %Accounts.Membership{} = membership,
        %SSO.IdentityProvider{} = provider
      ) do
    directory_sync_membership_event(membership, provider, "membership.reprovisioned_via_scim")
  end

  @doc "A membership role recomputed from the member's mapped IdP groups (Slice 2b). `membership` is the pre-update row, for the from→to payload."
  def membership_role_synced_via_scim(
        %Accounts.Membership{} = membership,
        %SSO.IdentityProvider{} = provider,
        new_role
      ) do
    Audit.changeset(membership.account_id, "membership.role_synced_via_scim",
      actor_kind: "directory_sync",
      actor_id: provider.id,
      actor_label: provider.name,
      subject_kind: "user",
      subject_id: membership.user_id,
      payload: %{
        provider_id: provider.id,
        provider_kind: to_string(provider.kind),
        from: to_string(membership.role),
        to: to_string(new_role)
      }
    )
  end

  defp directory_sync_membership_event(
         %Accounts.Membership{} = membership,
         %SSO.IdentityProvider{} = provider,
         event_type
       ) do
    Audit.changeset(membership.account_id, event_type,
      actor_kind: "directory_sync",
      actor_id: provider.id,
      actor_label: provider.name,
      subject_kind: "user",
      subject_id: membership.user_id,
      payload: %{provider_id: provider.id, provider_kind: to_string(provider.kind)}
    )
  end

  @doc "An IdP group→role mapping created by an operator (Slice 2b config)."
  def group_role_mapping_created(
        %Subject{} = subject,
        %SSO.IdentityProvider{} = provider,
        %SSO.GroupRoleMapping{} = mapping
      ),
      do: group_role_mapping_event(subject, mapping, "sso.group_mapping_created", provider)

  @doc "An IdP group→role mapping updated by an operator (role / display change)."
  def group_role_mapping_updated(%Subject{} = subject, %SSO.GroupRoleMapping{} = mapping),
    do: group_role_mapping_event(subject, mapping, "sso.group_mapping_updated", nil)

  @doc "An IdP group→role mapping deleted by an operator."
  def group_role_mapping_deleted(%Subject{} = subject, %SSO.GroupRoleMapping{} = mapping),
    do: group_role_mapping_event(subject, mapping, "sso.group_mapping_deleted", nil)

  defp group_role_mapping_event(
         %Subject{} = subject,
         %SSO.GroupRoleMapping{} = mapping,
         event_type,
         provider
       ) do
    Audit.changeset(
      mapping.account_id,
      event_type,
      actor(subject) ++
        [
          subject_kind: "identity_provider",
          subject_id: provider_id(provider, mapping),
          subject_label: mapping.external_group_display || mapping.external_group_id,
          payload: %{
            external_group_id: mapping.external_group_id,
            role: to_string(mapping.role)
          }
        ]
    )
  end

  defp provider_id(%SSO.IdentityProvider{id: id}, _mapping), do: id
  defp provider_id(nil, %SSO.GroupRoleMapping{provider_id: id}), do: id

  def identity_provider_configured(%Subject{} = subject, %SSO.IdentityProvider{} = provider),
    do: identity_provider_event(subject, provider, "sso.provider_configured")

  def identity_provider_updated(%Subject{} = subject, %SSO.IdentityProvider{} = provider),
    do: identity_provider_event(subject, provider, "sso.provider_updated")

  def identity_provider_deleted(%Subject{} = subject, %SSO.IdentityProvider{} = provider),
    do: identity_provider_event(subject, provider, "sso.provider_deleted")

  defp identity_provider_event(
         %Subject{} = subject,
         %SSO.IdentityProvider{} = provider,
         event_type
       ) do
    Audit.changeset(
      provider.account_id,
      event_type,
      actor(subject) ++
        [
          subject_kind: "identity_provider",
          subject_id: provider.id,
          subject_label: provider.name,
          payload: %{kind: to_string(provider.kind)}
        ]
    )
  end

  @doc "An admin approved a pending manual SSO link request — the captured identity is now provisioned. Actor is the admin."
  def sso_link_request_approved(
        %Subject{} = subject,
        %Users.User{} = user,
        %SSO.IdentityProvider{} = provider
      ) do
    Audit.changeset(
      provider.account_id,
      "sso.link_request_approved",
      actor(subject) ++
        [
          subject_kind: "user",
          subject_id: user.id,
          subject_label: user.email || user.full_name,
          payload: %{
            provider_id: provider.id,
            provider_kind: to_string(provider.kind),
            role: to_string(provider.default_role)
          }
        ]
    )
  end

  @doc "An admin linked an IdP identity to an EXISTING emisar user (no new user created). Actor is the admin."
  def sso_existing_user_linked(
        %Subject{} = subject,
        %Users.User{} = user,
        %SSO.IdentityProvider{} = provider
      ) do
    Audit.changeset(
      provider.account_id,
      "sso.existing_user_linked",
      actor(subject) ++
        [
          subject_kind: "user",
          subject_id: user.id,
          subject_label: user.email || user.full_name,
          payload: %{
            provider_id: provider.id,
            provider_kind: to_string(provider.kind)
          }
        ]
    )
  end

  @doc "An admin dismissed a pending manual SSO link request without provisioning. Actor is the admin."
  def sso_link_request_dismissed(%Subject{} = subject, %SSO.LinkRequest{} = request) do
    Audit.changeset(
      request.account_id,
      "sso.link_request_dismissed",
      actor(subject) ++
        [
          subject_kind: "identity_provider",
          subject_id: request.provider_id,
          subject_label: request.email || request.full_name || request.provider_identifier,
          payload: %{provider_id: request.provider_id}
        ]
    )
  end

  # -- Billing ---------------------------------------------------------

  @doc """
  The account's plan changed (Paddle webhook / sync). System actor, no user.
  DISTINCT from the Mixpanel `Analytics.Events.subscription_changed` — this is the
  in-app AUDIT trail (so a downgrade-to-wipe leaves evidence), not analytics.
  """
  def subscription_changed(account_id, from_plan, to_plan) when is_binary(account_id) do
    Audit.changeset(account_id, "subscription.changed",
      actor_kind: "system",
      subject_kind: "account",
      subject_id: account_id,
      payload: %{from: from_plan, to: to_plan}
    )
  end

  # -- Audit -----------------------------------------------------------

  @doc "Internal — the retention worker logs each account's pruned-count so the log never shrinks invisibly."
  def audit_retention_swept(account_id, count, %DateTime{} = swept_at)
      when is_binary(account_id) and is_integer(count) do
    Audit.changeset(account_id, "audit.retention_swept",
      actor_kind: "system",
      subject_kind: "audit_log",
      subject_label: "Audit log",
      payload: %{count: count, swept_at: DateTime.to_iso8601(swept_at)}
    )
  end

  @doc "Internal — `Audit.record_export/3` logs a non-empty audit-log export (the exfil signal)."
  def audit_exported(%Subject{account: %{id: account_id}} = subject, opts, count)
      when is_integer(count) do
    Audit.changeset(
      account_id,
      "audit.exported",
      actor(subject) ++
        [
          subject_kind: "audit_log",
          subject_label: "Audit log",
          payload: export_payload(opts, count)
        ]
    )
  end

  # -- Internals -------------------------------------------------------

  # The exported page's scope, for the audit reader: how many rows, the page cap,
  # any event-type filter, and the lower-bound position (a resumed cursor, a
  # `since` timestamp, or the beginning for a first full pull).
  defp export_payload(opts, count) do
    %{
      count: count,
      limit: Keyword.get(opts, :limit),
      event_types: Keyword.get(opts, :event_types, []),
      from: export_position(opts)
    }
  end

  defp export_position(opts) do
    case {Keyword.get(opts, :after), Keyword.get(opts, :since)} do
      {{%DateTime{} = ts, _id}, _} -> DateTime.to_iso8601(ts)
      {_, %DateTime{} = since} -> DateTime.to_iso8601(since)
      _ -> "beginning"
    end
  end

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

  defp member_event(%Subject{} = subject, %Accounts.Membership{} = membership, event_type) do
    Audit.changeset(
      membership.account_id,
      event_type,
      actor(subject) ++ [subject_kind: "user", subject_id: membership.user_id]
    )
  end

  defp user_event(
         %Subject{} = subject,
         %Accounts.Membership{} = membership,
         %Users.User{} = user,
         event_type
       ) do
    Audit.changeset(
      membership.account_id,
      event_type,
      actor(subject) ++ [subject_kind: "user", subject_id: user.id, subject_label: user.email]
    )
  end

  # Actor identity, session provenance, and the request context that
  # produced this event — all off the one `%Subject{}` every builder
  # already receives. So the request's ip/ua/request_id AND how the
  # caller authenticated ride the authenticated caller, not a
  # process-dictionary side channel.
  defp actor(%Subject{} = subject),
    do: [
      actor_kind: Subject.actor_kind(subject),
      actor_id: Subject.actor_id(subject),
      auth_method: format_auth_method(subject.auth_method),
      mfa: subject.mfa,
      user_identity_id: subject.user_identity_id,
      context: subject.context
    ]

  defp format_auth_method(nil), do: nil
  defp format_auth_method(method) when is_atom(method), do: Atom.to_string(method)
end
