defmodule Emisar.Checks.ShortBindings do
  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      House rule: spell variables out — `changeset`, not `cs`; `queryable`,
      not `q`.

      Flags assignments and function parameters bound to the known-bad
      short names. Query DSL bindings inside `where`/`order_by`/`select`/
      `dynamic`/… are a documented exception — but ONLY as a SINGLE letter
      (`[runs: r]`, `[group_members: g]`); a multi-letter abbreviation like
      `[group_members: gm]` is flagged, since the binding atom already names
      the table.
      """
    ]

  @banned [:q, :cs]

  # The query DSL macros whose binding-list arg (`[table: var]`) must use a
  # single-letter var — the `as:`/binding atom already carries the table name.
  @dsl_macros [
    :where,
    :or_where,
    :order_by,
    :group_by,
    :having,
    :select,
    :select_merge,
    :distinct,
    :dynamic
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

  # A query DSL macro in its 3-arg form — `where(q, [table: var], expr)` etc. —
  # carries its named binding in the 2nd arg. (The 2-arg form's 2nd arg is the
  # condition list, not a binding, so it's left alone.)
  defp walk({macro, _, args} = ast, ctx)
       when macro in @dsl_macros and is_list(args) and length(args) >= 3 do
    {ast, flag_binding_list(Enum.at(args, 1), ctx)}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  # A named binding list `[table: var, ...]` — flag any var longer than one char.
  defp flag_binding_list(arg, ctx) when is_list(arg) do
    Enum.reduce(arg, ctx, fn
      {binding, {var, meta, var_ctx}}, acc
      when is_atom(binding) and is_atom(var) and is_atom(var_ctx) ->
        maybe_flag_binding(acc, var, meta)

      _other, acc ->
        acc
    end)
  end

  defp flag_binding_list(_arg, ctx), do: ctx

  defp maybe_flag_binding(ctx, var, meta) do
    name = Atom.to_string(var)

    if String.length(name) > 1,
      do: put_issue(ctx, dsl_binding_issue(ctx, meta, name)),
      else: ctx
  end

  defp dsl_binding_issue(ctx, meta, name) do
    format_issue(
      ctx,
      message:
        "House rule: a query DSL binding is a single letter — `#{String.first(name)}`, not `#{name}`.",
      trigger: name,
      line_no: meta[:line],
      column: meta[:column]
    )
  end

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
