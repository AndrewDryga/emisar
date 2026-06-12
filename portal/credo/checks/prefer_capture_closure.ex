defmodule Emisar.Checks.PreferCaptureClosure do
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      House rule: a closure whose body is a single call uses capture syntax.

      `fn x -> f(x) end` is `&f/1`; with extra args it's `&f(&1, extra)`;
      a bare field read is `& &1.field`. `fn` earns its keep only for
      multi-step bodies, pattern-matching heads, multi-clause closures,
      zero-arity closures over scope values, closures nested inside an
      outer capture (pruned here — capture-in-capture won't compile), and
      arguments used more than once.
      """
    ]

  # Not convertible bodies: control flow, blocks, pipes — and the literal
  # constructors (binaries/tuples/maps/structs), which are not calls.
  @special_forms [
    :fn,
    :if,
    :unless,
    :case,
    :cond,
    :with,
    :for,
    :receive,
    :try,
    :quote,
    :=,
    :|>,
    :__block__,
    :&,
    :<<>>,
    :{},
    :%{},
    :%,
    :|,
    :"::"
  ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    result = Credo.Code.prewalk(source_file, &walk/2, ctx)
    result.issues
  end

  # A capture can't nest another capture — don't look inside `&`.
  defp walk({:&, _, _}, ctx), do: {nil, ctx}

  defp walk({:fn, meta, [{:->, _, [[{var, _, var_ctx}], body]}]} = ast, ctx)
       when is_atom(var) and is_atom(var_ctx) do
    if not String.starts_with?(Atom.to_string(var), "_") and convertible?(body, var) do
      {ast, put_issue(ctx, issue_for(ctx, meta, "fn #{var} ->"))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  # fn x -> x.field end  →  & &1.field
  defp convertible?({{:., _, [{var, _, _}, field]}, _, []}, var) when is_atom(field), do: true

  # fn x -> Mod.fun(..x..) end  →  &Mod.fun(..&1..)
  defp convertible?({{:., _, [_mod, fun]}, _, args} = body, var)
       when is_atom(fun) and is_list(args),
       do: used_exactly_once?(body, var) and not contains_capture?(body)

  # fn x -> fun(..x..) end  →  &fun(..&1..)
  defp convertible?({fun, _, args} = body, var)
       when is_atom(fun) and is_list(args) and fun not in @special_forms,
       do: used_exactly_once?(body, var) and not contains_capture?(body)

  defp convertible?(_, _), do: false

  # A capture argument inside the body blocks conversion — the outer
  # closure becoming a capture would nest captures, which won't compile.
  defp contains_capture?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:&, _, _} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  defp used_exactly_once?(body, var) do
    {_, count} =
      Macro.prewalk(body, 0, fn
        {^var, _, var_ctx} = node, acc when is_atom(var_ctx) -> {node, acc + 1}
        node, acc -> {node, acc}
      end)

    count == 1
  end

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: single-call forwarding closure — use capture syntax " <>
          "(&fun/1, &fun(&1, extra), or & &1.field).",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
