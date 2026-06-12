defmodule Emisar.Checks.IL12NoFloatMoney do
  use Credo.Check,
    base_priority: :higher,
    category: :warning,
    explanations: [
      check: """
      Iron Law IL-12: never `:float` for money.

      Floats lose cents and billing is real money (Paddle). Money-named
      schema fields and migration columns use `:decimal` or `:integer`
      (cents).
      """
    ]

  @money_prefix ~r/^(price|amount|cost|total|subtotal|balance|fee|rate|charge|payment|salary|wage|budget|revenue|discount|tax|cents|money)/

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    result = Credo.Code.prewalk(source_file, &walk/2, ctx)
    result.issues
  end

  defp walk({fun, meta, [name, :float | _]} = ast, ctx)
       when fun in [:field, :add] and is_atom(name) do
    if Regex.match?(@money_prefix, Atom.to_string(name)) do
      {ast, put_issue(ctx, issue_for(ctx, meta, "#{fun} :#{name}"))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message: "IL-12: :float for a money field — use :decimal or :integer (cents).",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
