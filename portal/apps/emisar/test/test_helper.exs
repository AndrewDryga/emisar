# Load every loaded application's modules before any test starts. In
# interactive mode async tests otherwise load modules lazily through the
# single code server; when many start at once on a busy machine those
# serialized loads stall tests past their timeouts.
for {app, _description, _version} <- Application.loaded_applications(),
    modules = Application.spec(app, :modules),
    is_list(modules) do
  Code.ensure_all_loaded(modules)
end

ExUnit.start(Emisar.ConcurrentProfileFormatter.options(capture_log: true))

if Process.whereis(Emisar.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Emisar.Repo, :manual)
end
