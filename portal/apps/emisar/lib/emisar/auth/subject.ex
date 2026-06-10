defmodule Emisar.Auth.Subject do
  @moduledoc """
  Authenticated caller carrier. Every public context function takes
  one to scope reads and authorize mutations. Built once at the
  boundary (UserAuth plug / LiveView mount, MCP controller plug,
  runner socket connect) and passed through unchanged.

  Fields:

    * `account` — the active `%Accounts.Account{}` (nil only for the
      rare actor-only case — a self-service edit that reads just `actor`)
    * `actor` — `%User{}`, `%ApiKey{}`, or `%Runner{}`
    * `role` — atom role identifier (`:owner | :admin | :operator |
      :viewer | :api_client | :runner`)
    * `permissions` — `MapSet.t()` of `{module, action}` tuples; the
      Authorizers build entries via `build/2`
    * `context` — extra metadata stamped onto audit events: `ip`,
      `user_agent`, `request_id`. Filled in by the boundary, read by
      `Audit` via `put_request_metadata/1`.
  """
  alias Emisar.Accounts.{Account, Membership, User}
  alias Emisar.Auth.Role

  @type role :: :owner | :admin | :operator | :viewer | :api_client | :runner
  @type permission :: {module(), atom()}
  @type actor ::
          Emisar.Accounts.User.t()
          | Emisar.ApiKeys.ApiKey.t()
          | Emisar.Runners.Runner.t()

  @type t :: %__MODULE__{
          account: Account.t() | nil,
          actor: actor() | nil,
          role: role() | nil,
          membership_id: binary() | nil,
          permissions: MapSet.t(),
          context: map()
        }

  defstruct account: nil,
            actor: nil,
            role: nil,
            membership_id: nil,
            permissions: MapSet.new(),
            context: %{}

  @doc "Build a subject from a `%User{}` + their `%Membership{}`."
  def for_user(%User{} = user, %Account{} = account, %Membership{} = membership, context \\ %{}) do
    role = role_atom(membership.role)

    %__MODULE__{
      account: account,
      actor: user,
      role: role,
      membership_id: membership.id,
      permissions: Emisar.Auth.Authorizer.permissions_for(role),
      context: context
    }
  end

  @doc "Build a subject for an API key call (MCP / programmatic)."
  def for_api_key(api_key, %Account{} = account, context \\ %{}) do
    %__MODULE__{
      account: account,
      actor: api_key,
      role: :api_client,
      # Keys mint-time-bound their creator's membership — MCP dispatch
      # uses this to apply per-user runner ACLs at call-time, so revoking
      # a user's runner scope immediately shrinks every key they minted.
      membership_id: Map.get(api_key, :created_by_membership_id),
      permissions: Emisar.Auth.Authorizer.permissions_for(:api_client),
      context: context
    }
  end

  @doc "Build a subject for the runner WebSocket caller."
  def for_runner(runner, %Account{} = account, context \\ %{}) do
    %__MODULE__{
      account: account,
      actor: runner,
      role: :runner,
      permissions: Emisar.Auth.Authorizer.permissions_for(:runner),
      context: context
    }
  end

  # Coerce a membership's role into a known role atom. Unknown values
  # fall back to the least-privileged role (default-deny posture).
  defp role_atom(role) do
    case Role.cast(role) do
      {:ok, role} -> role
      :error -> :viewer
    end
  end

  # -- Helpers used by every context's `ensure_X_in_subject_account` -

  @doc """
  String label for the subject's actor kind. Used by `Audit.log/3`
  callers to stamp the `actor_kind` field consistently.
  """
  def actor_kind(%__MODULE__{actor: %User{}}), do: "user"
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

  @doc """
  The acting user's email, or `nil` when the actor isn't a user
  (API key / runner / system). Used to attach the buyer's email to a
  Paddle customer for invoices and receipts.
  """
  def actor_email(%__MODULE__{actor: %User{email: email}}), do: email
  def actor_email(%__MODULE__{}), do: nil

  @doc """
  True iff the subject can act on data scoped to `account_id` — the
  account on its `%Subject{}` must match.
  """
  def in_account?(%__MODULE__{account: %Account{id: id}}, id), do: true
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
