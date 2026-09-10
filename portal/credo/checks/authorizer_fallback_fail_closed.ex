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

      The check reads the queryable's name from the head, so the first
      parameter must be a plain variable or `pattern = variable`
      (`%Ecto.Query{aliases: %{x: _}} = queryable`). Any other shape is
      reported rather than skipped: a clause the check cannot read is a clause
      it cannot vouch for.
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
      :unreadable -> {ast, put_issue(ctx, unreadable_issue_for(ctx, meta))}
      :error -> {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  # A guarded head wraps the call in `:when`. The guard only narrows which
  # subjects reach the clause; it never makes an open fallback safe, so both
  # shapes are analyzed identically.
  defp for_subject_head({:when, _, [head, _guard]}), do: for_subject_head(head)

  # `%Ecto.Query{…} = queryable` (or the reverse) names the queryable on one
  # side of the match. Read that side; the pattern is what the clause
  # dispatches on. Without this, `{:=, _, _}` matched the plain-variable shape
  # below and bound the name to the atom `:=`, so every later comparison
  # against the real variable missed and the clause was waved through.
  defp for_subject_head({:for_subject, _, [{:=, _, [left, right]}, subject]}) do
    cond do
      variable?(right) -> {:ok, variable_name(right), subject}
      variable?(left) -> {:ok, variable_name(left), subject}
      true -> :unreadable
    end
  end

  defp for_subject_head({:for_subject, _, [first, subject]}) do
    if variable?(first), do: {:ok, variable_name(first), subject}, else: :unreadable
  end

  defp for_subject_head(_head), do: :error

  # A variable node is `{name, meta, context}` with an atom context; operator
  # and struct nodes carry a list of arguments there instead.
  defp variable?({name, _, context}) when is_atom(name) and is_atom(context), do: true
  defp variable?(_ast), do: false

  defp variable_name({name, _, _}), do: name

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

  defp unreadable_issue_for(ctx, meta) do
    format_issue(
      ctx,
      message:
        "Authorizer.for_subject/2 must bind its queryable as a plain variable or " <>
          "`pattern = variable` so the fail-closed check can read the clause.",
      trigger: "for_subject",
      line_no: meta[:line],
      column: meta[:column]
    )
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
