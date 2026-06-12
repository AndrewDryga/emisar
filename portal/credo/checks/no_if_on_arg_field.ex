defmodule Emisar.Checks.NoIfOnArgField do
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      House rule: dispatch on a pattern, not an inner `if`.

      A closure whose body is an `if` testing the bare truthiness of its
      own argument's field is a pattern in disguise — write a two-clause
      named function instead (`%Struct{field: nil}` head + catch-all) and
      pass it by capture. `if` stays for genuinely computed conditions.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    result = Credo.Code.prewalk(source_file, &walk/2, ctx)
    result.issues
  end

  defp walk({:fn, meta, [{:->, _, [[{var, _, var_ctx}], {:if, _, [condition | _]}]}]} = ast, ctx)
       when is_atom(var) and is_atom(var_ctx) do
    case condition do
      {{:., _, [{^var, _, _}, field]}, _, []} when is_atom(field) ->
        {ast, put_issue(ctx, issue_for(ctx, meta, "if #{var}.#{field}"))}

      _ ->
        {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: closure dispatching on a field's truthiness — use function " <>
          "clause heads (%Struct{field: nil} head + catch-all) instead of an inner if.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
