defmodule Emisar.Checks.IL01NoInlineEctoDsl do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      Iron Law IL-1: no Ecto query DSL outside Query modules.

      Every queryable starts at `Schema.Query.fun()` — the Query module is
      the single place a table's shape is defined; inline DSL forks it.
      Query modules get the DSL via `use Emisar, :query`, so a literal
      `import Ecto.Query` (or a qualified `Ecto.Query.from(...)` call) has
      no legitimate home outside `lib/emisar.ex` and the `Repo` machinery.
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

  # The DSL is sanctioned only in the `use Emisar, :query` macro definition
  # and the Repo machinery (paginator/filter/query behaviour).
  defp relevant?(filename) do
    String.contains?(filename, "/lib/") and
      not String.ends_with?(filename, "lib/emisar.ex") and
      not String.ends_with?(filename, "lib/emisar/repo.ex") and
      not String.contains?(filename, "lib/emisar/repo/")
  end

  defp walk({:import, meta, [{:__aliases__, _, [:Ecto, :Query]} | _]} = ast, ctx) do
    {ast, put_issue(ctx, issue_for(ctx, meta, "import Ecto.Query"))}
  end

  defp walk({{:., _, [{:__aliases__, meta, [:Ecto, :Query]}, fun]}, _, args} = ast, ctx)
       when is_atom(fun) and is_list(args) do
    {ast, put_issue(ctx, issue_for(ctx, meta, "Ecto.Query.#{fun}"))}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "IL-1: Ecto query DSL outside a Query module — move the query into " <>
          "Schema.Query (`use Emisar, :query` there) and start pipelines at Schema.Query.fun().",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
