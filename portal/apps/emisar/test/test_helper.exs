ExUnit.start(capture_log: true)

if Process.whereis(Emisar.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Emisar.Repo, :manual)
end
