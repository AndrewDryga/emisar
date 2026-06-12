defmodule Emisar.Checks.NoPipeInBranchHead do
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      House rule: no pipe in a `with`/`case`/`for` head — single-line included.

      A pipeline in the expression being matched hides the operation the
      pattern tests. Bind it first (`queryable = Token.Query.all() ...`)
      and match the short call (`<- Repo.peek(queryable)`).
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
    String.contains?(filename, "/lib/") and not String.contains?(filename, "/test/")
  end

  defp walk({form, _, args} = ast, ctx) when form in [:with, :for] and is_list(args) do
    issues =
      for {:<-, meta, [_pattern, {:|>, _, _}]} <- args do
        issue_for(ctx, meta, "<-")
      end

    {ast, put_issue(ctx, issues)}
  end

  defp walk({:case, meta, [subject, blocks]} = ast, ctx) when is_list(blocks) do
    case subject do
      {:|>, _, _} -> {ast, put_issue(ctx, issue_for(ctx, meta, "case"))}
      _ -> {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: pipe in a with/case/for head — bind the pipeline to a name " <>
          "above the head, then match the short call.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
