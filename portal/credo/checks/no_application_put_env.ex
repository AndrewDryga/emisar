defmodule Emisar.Checks.NoApplicationPutEnv do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      No `Application.put_env` / `delete_env` / `put_all_env` in lib or test.
      Mutating global application env at runtime is process-global, so it races
      under `async: true` and forces the tests that touch it serial.

      Config a test (or dev) must override flows through the `Emisar.Config`
      seam: read with `Emisar.Config.get_env/3` / `fetch_env!/2`, override with
      `Emisar.Config.put_override/3` (test-only, scoped to the calling process
      and resolved across `$callers` / the sandbox `user-agent`). A third-party
      library that reads its own app env (e.g. a Swoosh adapter) gets a
      process-driven test double, not a global swap.
      """
    ]

  @forbidden [:put_env, :delete_env, :put_all_env]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "/lib/") or
         String.contains?(source_file.filename, "/test/") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({{:., _, [{:__aliases__, meta, [:Application]}, fun]}, _, args} = ast, ctx)
       when fun in @forbidden and is_list(args) do
    {ast, put_issue(ctx, issue_for(ctx, meta, fun))}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, fun) do
    format_issue(
      ctx,
      message:
        "Application.#{fun} mutates process-global app env (races under async) — " <>
          "override config with Emisar.Config.put_override/3 (test-scoped) and read " <>
          "through Emisar.Config.get_env/fetch_env!.",
      trigger: "Application.#{fun}",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
