# Load every loaded application's modules before any test starts; see
# apps/emisar/test/test_helper.exs for why.
for {app, _description, _version} <- Application.loaded_applications(),
    modules = Application.spec(app, :modules),
    is_list(modules) do
  Code.ensure_all_loaded(modules)
end

ExUnit.start(Emisar.ConcurrentProfileFormatter.options(capture_log: true))
Ecto.Adapters.SQL.Sandbox.mode(Emisar.Repo, :manual)
