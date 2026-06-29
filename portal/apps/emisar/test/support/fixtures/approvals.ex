defmodule Emisar.Fixtures.Approvals do
  @moduledoc """
  Approval test inspectors. Use via `alias Emisar.Fixtures` then
  `Fixtures.Approvals.grants_for_api_key/1`.
  """

  alias Emisar.{Approvals, Repo}

  @doc """
  Test-side inspector: the unrevoked grants minted against an API key,
  newest first. Verifies `approve_request/4` side effects without
  rebuilding the Subject-gated operator surface in test setup.
  """
  def grants_for_api_key(api_key_id) do
    Approvals.Grant.Query.not_revoked()
    |> Approvals.Grant.Query.by_api_key_id(api_key_id)
    |> Approvals.Grant.Query.ordered_by_recent()
    |> Repo.all()
  end
end
