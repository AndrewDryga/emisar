defmodule Emisar.Approvals.Grant do
  @moduledoc """
  A durable approval that lets future matching calls bypass the
  pending-approval gate. Created from an `Emisar.Approvals.Request`
  when an operator approves with a duration > "once-only".

  Match rules (the `peek_matching_grant/4` lookup in `Emisar.Approvals`):

    * `api_key_id` always matches the calling key exactly. Grants are
      scoped per key so that approving an action for one operator's
      LLM doesn't silently apply to a different key with different
      scopes.
    * `action_id` always matches exactly.
    * `runner_id` matches the runner, OR is `nil` which means "any
      runner advertising the action".
    * `args_sha256` matches the dispatched args' SHA-256, OR is `nil`
      which means "any args for this action".
    * `expires_at` is `nil` for indefinite, otherwise the grant is
      expired when `expires_at < now()`.
    * `max_uses` is `nil` for unlimited, otherwise the grant is
      consumed when `uses_count >= max_uses`.
    * `revoked_at` non-nil makes the grant unusable forever.
  """
  use Emisar, :schema

  schema "approval_grants" do
    field :action_id, :string
    field :args_sha256, :string

    field :granted_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec

    field :max_uses, :integer
    field :uses_count, :integer, default: 0

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :api_key, Emisar.ApiKeys.ApiKey, where: [deleted_at: nil]
    belongs_to :runner, Emisar.Runners.Runner, where: [deleted_at: nil]
    belongs_to :granted_by, Emisar.Accounts.User, where: [deleted_at: nil]
    belongs_to :revoked_by, Emisar.Accounts.User, where: [deleted_at: nil]
    belongs_to :approval_request, Emisar.Approvals.Request

    timestamps()
  end

  @doc "Is the grant still usable right now?"
  def usable?(grant, now \\ DateTime.utc_now())

  def usable?(%__MODULE__{revoked_at: r}, _) when not is_nil(r), do: false

  def usable?(%__MODULE__{expires_at: e} = grant, now) when not is_nil(e),
    do: DateTime.compare(now, e) == :lt and max_uses_remaining?(grant)

  def usable?(%__MODULE__{} = grant, _now), do: max_uses_remaining?(grant)

  defp max_uses_remaining?(%__MODULE__{max_uses: nil}), do: true
  defp max_uses_remaining?(%__MODULE__{max_uses: max, uses_count: n}), do: n < max
end
