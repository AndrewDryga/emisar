defmodule Emisar.Checks.IL06QueryModulePure do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      Iron Law IL-6: Query modules build queryables; they never call Repo.

      A `Repo.*` call inside `<schema>/query.ex` couples query composition
      to execution — the context is the layer that calls Repo, so helpers
      stay safe to chain in any order.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if relevant?(source_file.filename) do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp relevant?(filename) do
    String.ends_with?(filename, "/query.ex") and
      not String.contains?(filename, "lib/emisar/repo/")
  end

  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when is_atom(fun) and is_list(args) do
    if List.last(parts) == :Repo do
      {ast, put_issue(ctx, issue_for(ctx, meta, "Repo.#{fun}"))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "IL-6: #{trigger} inside a Query module — Query modules only build " <>
          "queryables; the context calls Repo.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
