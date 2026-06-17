defmodule Emisar.Checks.TestContextPattern do
  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      House rule (§7): a test's context is an explicit `%{...}` pattern in the
      head, never a bare `ctx`/`context`. `test "…", %{account: account} do`
      reads the test's real dependencies at a glance, and an unused setup key
      becomes a warning. `test "…", ctx do` then `ctx.account` hides what the
      test depends on and silences the unused checks.

      Allowed: no context arg at all, an `%{...}` pattern, a `%{...} = ctx`
      binding, or a `_`-prefixed ignore. Only a bare named variable is flagged.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "/test/") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  # test "name", <ctx> do … end  — a bare variable as the context arg (3rd element
  # is the var's hygiene context, an atom, not a call's arg list).
  defp walk({:test, meta, [_name, {var, _, mod} | _]} = ast, ctx)
       when is_atom(var) and is_atom(mod) do
    if underscore?(var) do
      {ast, ctx}
    else
      {ast, put_issue(ctx, issue_for(ctx, meta, var))}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp underscore?(var), do: var |> Atom.to_string() |> String.starts_with?("_")

  defp issue_for(ctx, meta, var) do
    format_issue(
      ctx,
      message:
        "§7: test binds its context as `#{var}` — use an explicit `%{...}` pattern in the " <>
          "head so the test's dependencies read at a glance and unused setup keys warn.",
      trigger: "#{var}",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
