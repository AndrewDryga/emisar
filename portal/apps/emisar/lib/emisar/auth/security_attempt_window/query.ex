defmodule Emisar.Auth.SecurityAttemptWindow.Query do
  use Emisar, :query
  alias Emisar.Auth.SecurityAttemptWindow

  def all, do: from(windows in SecurityAttemptWindow, as: :windows)

  def by_user_and_scope(queryable \\ all(), user_id, scope) do
    where(queryable, [windows: w], w.user_id == ^user_id and w.scope == ^scope)
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR NO KEY UPDATE")

  # Called only after this transaction owns the row lock. Sampling the clock in
  # the locking SELECT can happen before PostgreSQL waits for a contended lock,
  # shortening or incorrectly extending the effective window.
  def select_database_time(queryable),
    do: select(queryable, type(fragment("clock_timestamp()"), :utc_datetime_usec))

  @impl Emisar.Repo.Query
  def preloads, do: []
end
