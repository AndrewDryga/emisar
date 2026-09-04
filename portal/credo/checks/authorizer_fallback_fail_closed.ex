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

      EVERY fallback in the clause is judged, not only the last one written: an
      open `case` earlier in the body leaks exactly as much as one at the end,
      and a `cond`'s `true ->` is a catch-all like `_ ->`. A guard on the head
      (`def for_subject(queryable, subject) when …`) changes nothing either — it
      narrows which subjects arrive, never what the fallback hands back.

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

  defp walk({:def, meta, [head, [do: body]]} = ast, ctx) do
    case for_subject_head(head) do
      {:ok, queryable, subject} -> {ast, judge(ctx, meta, body, queryable, subject)}
      :error -> {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  # A guarded head wraps the call in `:when`. The guard only narrows which
  # subjects reach the clause; it never makes an open fallback safe, so both
  # shapes are analyzed identically.
  defp for_subject_head({:when, _, [head, _guard]}), do: for_subject_head(head)

  defp for_subject_head({:for_subject, _, [{queryable, _, _}, subject]}) when is_atom(queryable),
    do: {:ok, queryable, subject}

  defp for_subject_head(_head), do: :error

  defp judge(ctx, meta, body, queryable, subject) do
    open? =
      (wildcard_subject?(subject) and not fail_closed?(body, queryable)) or
        open_fallback?(body, queryable)

    if open?, do: put_issue(ctx, issue_for(ctx, meta)), else: ctx
  end

  defp wildcard_subject?({subject, _, _}) when is_atom(subject),
    do: subject |> Atom.to_string() |> String.starts_with?("_")

  defp wildcard_subject?(_subject), do: false

  # Any `case`/`with … else`/`cond` catch-all that hands the queryable back
  # unchanged — every row of every account. Accumulated with `or`: the last
  # fallback written is not the only one that leaks.
  defp open_fallback?(body, queryable) do
    {_ast, open?} =
      Macro.prewalk(body, false, fn
        {:->, _, [[pattern], {^queryable, _, _}]} = node, acc ->
          {node, acc or fallback_pattern?(pattern)}

        node, acc ->
          {node, acc}
      end)

    open?
  end

  # What a clause catches when every named clause missed: `_`/`_source` in a
  # `case` or a `with … else`, and `true` in a `cond`.
  defp fallback_pattern?(true), do: true
  defp fallback_pattern?(pattern), do: wildcard_subject?(pattern)

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
