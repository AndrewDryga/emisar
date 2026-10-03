defmodule Emisar.Auth.Subject do
  @moduledoc """
  Authenticated caller carrier. Every public context function takes
  one to scope reads and authorize mutations. Built once at the
  boundary (UserAuth plug / LiveView mount, MCP controller plug,
  runner socket connect) and passed through unchanged.

  Fields:

    * `account` — the active `%Accounts.Account{}` (nil only for the
      rare actor-only case — a self-service edit that reads just `actor`)
    * `actor` — the `%Accounts.Membership{}` a person acts as, `%ApiKey{}`, or
      `%Runner{}`
    * `role` — atom role identifier (`:owner | :admin | :operator |
      :viewer | :api_client | :runner`)
    * `permissions` — `MapSet.t()` of `{module, action}` tuples; the
      Authorizers build entries via `build/2`
    * `context` — the request's `%RequestContext{}` (IP address, user agent,
      request ID, and MCP client metadata). Filled in by the boundary; the
      `Audit.Events` builders read it off the subject and stamp it onto
      every event the caller produces.
    * `auth_method` — how this session was authenticated (`:magic_link |
      :sso`), or nil for an API key / runner (the actor IS the credential).
      Stamped onto every audit row.
    * `mfa` — whether a second factor is verified for this session (TOTP, or an
      IdP assertion). `true`/`false` for a session, nil otherwise. Local
      proof is bound to the current enrollment; SSO proof is the assurance
      recorded at authentication time while the provider still satisfies MFA.
      The raw `mfa_verified_at` stays on the session row for forensics.
    * `mfa_enrollment_verified_at` — the exact local-TOTP enrollment epoch this
      session proved, or nil. Consumers compare it with the Member's current
      `mfa_enabled_at`; carrying the epoch rather than a boolean lets a locked
      re-read reject a disable/re-enroll race.
    * `user_identity_id` — the `%SSO.UserIdentity{}` behind an `:sso`
      session; nil otherwise.
    * `session_token_id` — the exact live session row this Member acts
      through. A Member Subject without one cannot act in a workspace.
  """
  alias Emisar.{Accounts, RequestContext}
  alias Emisar.Auth.UserToken

  @type role :: :owner | :admin | :operator | :viewer | :api_client | :runner
  @type permission :: {module(), atom()}
  @type auth_method :: :magic_link | :sso
  @type actor ::
          Emisar.Accounts.Membership.t()
          | Emisar.ApiKeys.ApiKey.t()
          | Emisar.Runners.Runner.t()

  @type t :: %__MODULE__{
          account: Accounts.Account.t() | nil,
          actor: actor() | nil,
          role: role() | nil,
          membership_id: binary() | nil,
          permissions: MapSet.t(),
          context: RequestContext.t(),
          auth_method: auth_method() | nil,
          mfa: boolean() | nil,
          mfa_enrollment_verified_at: DateTime.t() | nil,
          user_identity_id: binary() | nil,
          session_token_id: binary() | nil
        }

  defstruct account: nil,
            actor: nil,
            role: nil,
            membership_id: nil,
            permissions: MapSet.new(),
            context: %RequestContext{},
            auth_method: nil,
            mfa: nil,
            mfa_enrollment_verified_at: nil,
            user_identity_id: nil,
            session_token_id: nil

  @doc """
  Build a subject for a workspace `%Accounts.Membership{}` acting in `account`;
  the Member is the actor. `opts` carry session provenance — `:auth_method`,
  `:mfa`, `:mfa_enrollment_verified_at`, `:user_identity_id` and
  `:session_token_id` — threaded from the session row so every audit row
  records it.
  """
  def for_member(
        %Accounts.Membership{} = membership,
        %Accounts.Account{} = account,
        context \\ %RequestContext{},
        opts \\ []
      ) do
    role = effective_membership_role(membership)

    %__MODULE__{
      account: account,
      actor: membership,
      role: role,
      membership_id: membership.id,
      permissions: Emisar.Auth.Permissions.for_role(role),
      context: context,
      auth_method: Keyword.get(opts, :auth_method),
      mfa: Keyword.get(opts, :mfa),
      mfa_enrollment_verified_at: Keyword.get(opts, :mfa_enrollment_verified_at),
      user_identity_id: Keyword.get(opts, :user_identity_id),
      session_token_id: Keyword.get(opts, :session_token_id)
    }
  end

  @doc """
  Build the Subject one live session authenticates: its Member, acting in its
  workspace, with the session's provenance. The session must arrive with its
  authority preloaded (`UserToken.Query.with_preloaded_authority/1`). Local MFA
  counts only while the session's proof matches the Member's current enrollment
  and has not expired; IdP MFA counts only while the provider still satisfies
  MFA. Pure: the caller already ran the per-request predicate.
  """
  def for_session(
        %UserToken{
          membership: %Accounts.Membership{account: %Accounts.Account{} = account} = membership
        } = session,
        %RequestContext{} = context
      ) do
    local_epoch = local_mfa_epoch(membership, session)

    for_member(membership, account, context,
      auth_method: session.auth_method,
      mfa: not is_nil(local_epoch) or idp_mfa?(session),
      mfa_enrollment_verified_at: local_epoch,
      user_identity_id: session.user_identity_id,
      session_token_id: session.id
    )
  end

  defp local_mfa_epoch(
         %Accounts.Membership{mfa_enabled_at: %DateTime{} = enabled_at},
         %UserToken{
           mfa_enrollment_verified_at: %DateTime{} = verified_enrollment,
           local_mfa_expires_at: %DateTime{} = expires_at
         }
       )
       when enabled_at == verified_enrollment do
    if DateTime.after?(expires_at, DateTime.utc_now()), do: enabled_at
  end

  defp local_mfa_epoch(_membership, _session), do: nil

  defp idp_mfa?(%UserToken{
         auth_method: :sso,
         mfa_verified_at: %DateTime{},
         user_identity: %{provider: %{satisfies_mfa: true}}
       }),
       do: true

  defp idp_mfa?(%UserToken{}), do: false

  @doc """
  Rebuild locked Member/account facts, keeping the bearer's actor and session
  provenance and never widening permissions.
  """
  def rebuild(
        %__MODULE__{} = subject,
        %Accounts.Membership{} = membership,
        %Accounts.Account{} = account
      ) do
    role = effective_membership_role(membership)
    permissions = Emisar.Auth.Permissions.for_role(role)

    %{
      subject
      | account: account,
        role: role,
        membership_id: membership.id,
        permissions: MapSet.intersection(subject.permissions, permissions)
    }
  end

  @doc "Build a subject for an API key call (MCP / programmatic)."
  def for_api_key(api_key, %Accounts.Account{} = account, context \\ %RequestContext{}) do
    %__MODULE__{
      account: account,
      actor: api_key,
      role: :api_client,
      # Keys mint-time-bound their creator's membership — MCP dispatch
      # uses this to apply per-user runner ACLs at call-time, so revoking
      # a user's runner scope immediately shrinks every key they minted.
      membership_id: Map.get(api_key, :created_by_membership_id),
      permissions: Emisar.Auth.Permissions.for_role(:api_client),
      context: context
    }
  end

  @doc "The membership role currently allowed to authorize work, including fail-closed state."
  def effective_membership_role(%Accounts.Membership{} = membership) do
    if Accounts.Membership.authorizable?(membership),
      do: authorizable_membership_role(membership),
      else: nil
  end

  # Directory changes fail closed while their durable role + runner-access
  # reconciliation is pending. A human owner remains an owner; directory sync
  # is never allowed to grant or revoke that role.
  defp authorizable_membership_role(%Accounts.Membership{role: :owner}), do: :owner

  defp authorizable_membership_role(%Accounts.Membership{
         directory_authorization_pending_version: version
       })
       when is_integer(version),
       do: :viewer

  defp authorizable_membership_role(%Accounts.Membership{role: role}), do: role

  # -- Helpers used by every context's `ensure_X_in_subject_account` -

  @doc """
  String label for the subject's audit actor kind. A person acts in a workspace
  as its exact Member (`"membership"`, see `human_membership_id/1`); an API key
  stays `"api_key"` even though it records its creator's Member.
  """
  def actor_kind(%__MODULE__{actor: %Accounts.Membership{}}), do: "membership"
  def actor_kind(%__MODULE__{actor: %Emisar.ApiKeys.ApiKey{}}), do: "api_key"
  def actor_kind(%__MODULE__{actor: %Emisar.Runners.Runner{}}), do: "runner"
  # Defensive fallback: an actor-less subject (anonymous bootstrap) is a system
  # actor rather than a FunctionClauseError downstream.
  def actor_kind(%__MODULE__{}), do: "system"

  @doc """
  The actor's id, or `nil` for an actor-less subject.
  """
  def actor_id(%__MODULE__{actor: %{id: id}}), do: id
  def actor_id(%__MODULE__{}), do: nil

  @doc "The exact acting human Member, never an API key's owner or a system actor."
  def human_membership_id(%__MODULE__{actor: %Accounts.Membership{}, membership_id: id}), do: id
  def human_membership_id(%__MODULE__{}), do: nil

  @doc """
  The acting API key's id, or `nil` when the actor isn't an API key (user /
  runner / system). Used for API-key attribution and credential-bound domain
  operations.
  """
  def api_key_id(%__MODULE__{actor: %Emisar.ApiKeys.ApiKey{id: id}}), do: id
  def api_key_id(%__MODULE__{}), do: nil

  @doc """
  True iff the subject can act on data scoped to `account_id` — the
  account on its `%Subject{}` must match.
  """
  def in_account?(%__MODULE__{account: %Accounts.Account{id: id}}, id), do: true
  def in_account?(_subject, _account_id), do: false

  @doc """
  `:ok` when `in_account?/2` would be true, `{:error, error_atom}`
  otherwise. Defaults to `:not_found` so cross-account access leaks
  no information about whether the row exists; pass `:unauthorized`
  for paths where the operator already proved scope.
  """
  def ensure_in_account(subject, account_id, error_atom \\ :not_found) do
    if in_account?(subject, account_id), do: :ok, else: {:error, error_atom}
  end
end
