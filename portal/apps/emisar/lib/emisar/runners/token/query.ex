defmodule Emisar.Runners.Token.Query do
  use Emisar, :query

  def all,
    do: from(tokens in Emisar.Runners.Token, as: :tokens)

  def by_id(q, id),
    do: where(q, [tokens: t], t.id == ^id)

  def by_runner_id(q, runner_id),
    do: where(q, [tokens: t], t.runner_id == ^runner_id)

  def by_prefix(q, prefix),
    do: where(q, [tokens: t], t.token_prefix == ^prefix)

  def by_runner_account_id(q, account_id) do
    q
    |> join(:inner, [tokens: t], r in ^Emisar.Runners.Runner.Query.all(),
      on: r.id == t.runner_id,
      as: :runners
    )
    |> where([runners: r], r.account_id == ^account_id)
  end
end
