defmodule Emisar.Fixtures.Approvals do
  @moduledoc """
  Approval test inspectors. Use via `alias Emisar.Fixtures` then
  `Fixtures.Approvals.grants_for_api_key/1`.
  """

  import Ecto.Changeset, only: [change: 2]
  alias Emisar.{Approvals, Fixtures, Repo}

  @doc """
  Persists a `:pending` approval request by default. Caller supplies
  `:account_id` (a run is created in it) or `:run_id`. Override `:status` (sets
  `decided_at`) and `:requested_at` (to land it in a report window).
  """
  def create_request(attrs \\ %{}) do
    attrs = Map.new(attrs)

    run =
      if attrs[:run_id],
        do: nil,
        else: Fixtures.Runs.create_run(Map.take(attrs, [:account_id]))

    params = %{
      account_id: attrs[:account_id] || run.account_id,
      run_id: attrs[:run_id] || run.id,
      requested_at: attrs[:requested_at] || DateTime.utc_now(),
      reason: attrs[:reason]
    }

    {:ok, request} = params |> Approvals.Request.Changeset.create() |> Repo.insert()

    case attrs[:status] do
      status when is_atom(status) and not is_nil(status) ->
        request |> change(status: status, decided_at: DateTime.utc_now()) |> Repo.update!()

      nil ->
        request
    end
  end

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
