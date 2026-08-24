# oidcc 3.7.2 exposes timeout/TLS/profile but not httpc's redirect and retry
# switches. OTP's synchronous timeout also cancels on the default profile even
# when the request uses another one, so an automatic redirect or Retry-After
# retry can keep running after oidcc has returned `:timeout`. Patch the one
# adapter choke point until upstream exposes these request options.
app = File.read!("src/oidcc.app.src")

unless app =~ ~s({vsn, "3.7.2"}) do
  raise "oidcc bounded-HTTP patch only supports the reviewed 3.7.2 source"
end

path = "src/oidcc_http_util.erl"
source = File.read!(path)
original = "    HttpOpts0 = [{timeout, Timeout}],"
bounded = "    HttpOpts0 = [{autoredirect, false}, {autoretry, 0}, {timeout, Timeout}],"

cond do
  source =~ bounded ->
    :ok

  source =~ original ->
    File.write!(path, String.replace(source, original, bounded))

  true ->
    raise "oidcc HTTP adapter drifted; review the bounded-HTTP patch before upgrading"
end

# A custom dependency compiler runs out-of-process while Mix owns the parent
# build lock. Compile into a dependency-local scratch path, then copy the exact
# app artifact into the parent path Mix supplied through ERL_LIBS. Compiling
# directly into that parent path would deadlock on the lock held by
# `mix deps.compile` itself.
parent_lib = System.fetch_env!("ERL_LIBS") |> Path.expand()
scratch_build = Path.expand("_build/emisar_bounded_http")
scratch_lib = Path.join(scratch_build, "lib")

File.rm_rf!(scratch_build)
File.mkdir_p!(scratch_lib)

for app <- File.ls!(parent_lib), app != "oidcc" do
  source = Path.join(parent_lib, app)

  if File.dir?(source) do
    File.ln_s!(source, Path.join(scratch_lib, app))
  end
end

{output, status} =
  System.cmd(
    "mix",
    ["compile", "--force", "--no-deps-check", "--no-code-path-pruning"],
    env: [
      {"ERL_LIBS", parent_lib},
      {"MIX_BUILD_PATH", scratch_build},
      {"MIX_ENV", "prod"}
    ],
    stderr_to_stdout: true
  )

IO.write(output)

unless status == 0 do
  raise "oidcc bounded-HTTP dependency compilation failed"
end

compiled_app = Path.join([scratch_build, "lib", "oidcc"])
target_app = Path.join(parent_lib, "oidcc")
File.rm_rf!(target_app)
{:ok, _copied} = File.cp_r(compiled_app, target_app)
