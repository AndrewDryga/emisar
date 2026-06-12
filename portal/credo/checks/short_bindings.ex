defmodule Emisar.Checks.ShortBindings do
  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      House rule: spell variables out — `changeset`, not `cs`; `queryable`,
      not `q`.

      Flags assignments and function parameters bound to the known-bad
      short names. (Query DSL bindings like `[runs: r]` inside
      `where`/`dynamic` are the documented idiom and are not bindings in
      this sense — they're unaffected.)
      """
    ]

  @banned [:q, :cs]

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

  defp walk({:=, _, [pattern, _value]} = ast, ctx) do
    {ast, flag_banned_vars(pattern, ctx)}
  end

  defp walk({:fn, _, clauses} = ast, ctx) when is_list(clauses) do
    issues_ctx =
      Enum.reduce(clauses, ctx, fn
        {:->, _, [params, _body]}, acc -> flag_banned_vars(params, acc)
        _, acc -> acc
      end)

    {ast, issues_ctx}
  end

  defp walk({def_kind, _, [head | _]} = ast, ctx) when def_kind in [:def, :defp] do
    {ast, flag_banned_vars(def_params(head), ctx)}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp def_params({:when, _, [inner | _]}), do: def_params(inner)
  defp def_params({_name, _, params}) when is_list(params), do: params
  defp def_params(_), do: []

  defp flag_banned_vars(pattern, ctx) do
    {_, ctx} =
      Macro.prewalk(pattern, ctx, fn
        {var, meta, var_ctx} = node, acc when var in @banned and is_atom(var_ctx) ->
          {node, put_issue(acc, issue_for(acc, meta, "#{var}"))}

        node, acc ->
          {node, acc}
      end)

    ctx
  end

  defp issue_for(ctx, meta, trigger) do
    suggestion = if trigger == "q", do: "queryable", else: "changeset"

    format_issue(
      ctx,
      message: "House rule: spell the binding out — `#{suggestion}`, not `#{trigger}`.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
