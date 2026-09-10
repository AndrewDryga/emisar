defmodule Emisar.Checks.RepoExistsOverCount do
  use Credo.Check,
    base_priority: :normal,
    category: :refactor,
    explanations: [
      check: """
      House rule: existence checks use `Repo.exists?/1`, never a count
      compared against zero.

      `Repo.aggregate(query, :count) > 0` scans every matching row to
      answer a boolean; `Repo.exists?` stops at the first hit.
      """
    ]

  @comparison_ops [:>, :<, :==, :!=, :>=, :<=]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "/lib/") and
         not String.contains?(source_file.filename, "/test/") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({op, meta, [left, right]} = ast, ctx) when op in @comparison_ops do
    if (aggregate_count?(left) and right == 0) or (left == 0 and aggregate_count?(right)) do
      {ast, put_issue(ctx, issue_for(ctx, meta))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  # Only a :count compared with zero is an existence check in disguise; a
  # :sum or :max against zero is a real comparison.
  defp aggregate_count?(
         {{:., _, [{:__aliases__, _, parts}, :aggregate]}, _, [_query, :count | _]}
       ),
       do: List.last(parts) == :Repo

  # query |> Repo.aggregate(:count, ...) piped into the comparison
  defp aggregate_count?(
         {:|>, _, [_, {{:., _, [{:__aliases__, _, parts}, :aggregate]}, _, [:count | _]}]}
       ),
       do: List.last(parts) == :Repo

  defp aggregate_count?(_), do: false

  defp issue_for(ctx, meta) do
    format_issue(
      ctx,
      message:
        "House rule: count compared against zero — use Repo.exists?(query); " <>
          "it stops at the first matching row.",
      trigger: "Repo.aggregate",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
