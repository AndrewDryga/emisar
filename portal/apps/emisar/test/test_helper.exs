ExUnit.start(exclude: [:db], capture_log: true)

# Sandbox setup only runs when the Repo can actually start. The
# unit-test subset (`mix test --exclude db`) runs without a DB and
# skips this.
if Process.whereis(Emisar.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Emisar.Repo, :manual)
end
