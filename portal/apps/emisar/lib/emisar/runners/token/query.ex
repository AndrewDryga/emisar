defmodule Emisar.Runners.Token.Query do
  use Emisar, :query

  def all,
    do: from(tokens in Emisar.Runners.Token, as: :tokens)

  def by_id(queryable, id),
    do: where(queryable, [tokens: t], t.id == ^id)

  def by_runner_id(queryable, runner_id),
    do: where(queryable, [tokens: t], t.runner_id == ^runner_id)

  def by_issued_via_key_id(queryable, key_id),
    do: where(queryable, [tokens: t], t.issued_via_key_id == ^key_id)

  def unused(queryable),
    do: where(queryable, [tokens: t], is_nil(t.last_used_at))

  def by_prefix(queryable, prefix),
    do: where(queryable, [tokens: t], t.token_prefix == ^prefix)

  def by_runner_account_id(queryable, account_id) do
    queryable
    |> join(:inner, [tokens: t], r in ^Emisar.Runners.Runner.Query.not_deleted(),
      on: r.id == t.runner_id,
      as: :runners
    )
    |> where([runners: r], r.account_id == ^account_id)
  end
end
