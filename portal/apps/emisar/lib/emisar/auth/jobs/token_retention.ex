defmodule Emisar.Auth.Jobs.TokenRetention do
  @moduledoc """
  Daily sweep that deletes user tokens past their own context's validity window.

  Expiry was enforced only on the read path, so the table kept every abandoned
  magic link, every unconfirmed email change, and every session nobody signed
  out of — rows that can never authenticate again but still carry a token digest
  and a user reference.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.hours(24),
    initial_delay: :timer.minutes(9),
    executor: Emisar.Jobs.Executors.GloballyUnique

  alias Emisar.Auth.UserToken
  alias Emisar.Repo
  require Logger

  @batch_size 5_000

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(_config) do
    deleted_count = delete_in_batches(0)

    if deleted_count > 0 do
      Logger.info("auth.user_tokens_swept", count: deleted_count)
    end

    :ok
  end

  defp delete_in_batches(deleted_total) do
    ids = @batch_size |> UserToken.Query.prunable_ids() |> Repo.all()
    {deleted_count, _} = UserToken.Query.all() |> UserToken.Query.by_ids(ids) |> Repo.delete_all()
    deleted_total = deleted_total + deleted_count

    if length(ids) == @batch_size do
      delete_in_batches(deleted_total)
    else
      deleted_total
    end
  end
end
