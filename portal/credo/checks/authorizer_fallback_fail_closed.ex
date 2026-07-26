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

      This is defense-in-depth for a future caller that reaches row scoping
      without first passing the permission gate.
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
            {:for_subject, _, [{queryable, _, _}, {subject, _, _}]},
            [do: body]
          ]} = ast,
         ctx
       )
       when is_atom(queryable) and is_atom(subject) do
    if wildcard?(subject) and not fail_closed?(body, queryable) do
      {ast, put_issue(ctx, issue_for(ctx, meta))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp wildcard?(subject),
    do: subject |> Atom.to_string() |> String.starts_with?("_")

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
