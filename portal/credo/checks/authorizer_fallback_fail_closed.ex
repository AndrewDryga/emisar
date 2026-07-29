defmodule Emisar.Checks.AuthorizerFallbackFailClosed do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      Authorizer row-scoping fallbacks fail closed. A subject that matches no
      account- or actor-specific clause must receive a binding-free zero-row
      query through the selected schema's `Query.none/1` helper, never the
      original unscoped queryable.

          # ❌
          def for_subject(queryable, _), do: queryable

          # ✅
          def for_subject(queryable, _), do: Runbook.Query.none(queryable)

      The same applies to a `case` on the query source INSIDE a clause: an
      unrecognized source must get `Query.none/1`, not the queryable it came in
      with.

          # ❌
          case query_source(queryable) do
            :runbooks -> Runbook.Query.by_account_id(queryable, id)
            _ -> queryable
          end

      This is defense-in-depth for a future caller that reaches row scoping
      without first passing the permission gate — and for the next query module
      added to such a `case` without its own clause.
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
    String.ends_with?(filename, "/authorizer.ex") and
      not String.ends_with?(filename, "/auth/authorizer.ex")
  end

  defp walk(
         {:def, meta,
          [
            {:for_subject, _, [{queryable, _, _}, subject]},
            [do: body]
          ]} = ast,
         ctx
       )
       when is_atom(queryable) do
    cond do
      wildcard_subject?(subject) and not fail_closed?(body, queryable) ->
        {ast, put_issue(ctx, issue_for(ctx, meta))}

      open_case_fallback?(body, queryable) ->
        {ast, put_issue(ctx, issue_for(ctx, meta))}

      true ->
        {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp wildcard_subject?({subject, _, _}) when is_atom(subject),
    do: subject |> Atom.to_string() |> String.starts_with?("_")

  defp wildcard_subject?(_subject), do: false

  # A `case` branching on the query source whose catch-all hands back the
  # queryable unchanged — every row of every account.
  defp open_case_fallback?(body, queryable) do
    {_ast, open?} =
      Macro.prewalk(body, false, fn
        {:->, _, [[pattern], {^queryable, _, _}]} = node, _acc ->
          {node, wildcard_subject?(pattern)}

        node, acc ->
          {node, acc}
      end)

    open?
  end

  defp fail_closed?(body, queryable) do
    case body do
      {{:., _, [{:__aliases__, _, parts}, :none]}, _, [{^queryable, _, _}]} ->
        List.last(parts) == :Query

      _ ->
        false
    end
  end

  defp issue_for(ctx, meta) do
    format_issue(
      ctx,
      message:
        "Authorizer.for_subject/2 catch-all must fail closed with " <>
          "Schema.Query.none(queryable), never return an unscoped query.",
      trigger: "for_subject",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
