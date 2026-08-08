defmodule Emisar.Checks.NoHashPrefixSlice do
  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      House rule: a content hash or machine id is passed to the view in FULL and
      left to the container to fit — never hard-sliced to a fixed prefix in
      Elixir.

          # ❌ — always trims, even when the slot has room to show it all
          "sha256:\#{String.slice(sha, 0, 16)}…"

          # ✅ — pass the whole value; let `truncate` + `title` fit it
          "sha256:\#{sha}"

      A fixed slice means the operator can never read the full value even where
      it would fit — the run-detail Arguments panel rendered `sha256:e23bd…` in
      an otherwise-empty header. Let the surrounding `truncate` show it fully
      when there is space and ellipsize only when narrow.

      Only hash/id-shaped subjects are flagged. Truncating prose to a display
      length (`String.slice(title, 0, 80)`) is a different job and stays legal.
      """
    ]

  @hashish ~r/(^|_)(hash|sha|digest|fingerprint|signature|sig|id)(_|$)/

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

  # The rule is about what reaches a rendered surface, so it is scoped to the
  # web app; a context slicing a digest for storage is not this defect.
  defp relevant?(filename) do
    String.contains?(filename, "emisar_web/lib/") and not String.contains?(filename, "/test/")
  end

  defp walk(
         {{:., _, [{:__aliases__, _, [:String]}, :slice]}, meta, [subject, 0, length]} = ast,
         ctx
       )
       when is_integer(length) do
    if hashish?(subject) do
      {ast, put_issue(ctx, issue_for(ctx, meta))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp hashish?(subject) do
    subject
    |> identifiers()
    |> Enum.any?(&Regex.match?(@hashish, Atom.to_string(&1)))
  end

  # Collect every identifier in the sliced expression, so both a bare `sha` and
  # a field read like `version.advertised_hash` are seen.
  defp identifiers(ast) do
    {_ast, names} =
      Macro.prewalk(ast, [], fn
        {name, _meta, context} = node, acc when is_atom(name) and is_atom(context) ->
          {node, [name | acc]}

        {:., _meta, [_base, field]} = node, acc when is_atom(field) ->
          {node, [field | acc]}

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp issue_for(ctx, meta) do
    format_issue(
      ctx,
      message:
        "House rule: a hash/id is hard-sliced to a fixed prefix — pass the full value and let " <>
          "the container's `truncate` + `title` fit it, so it reads in full where there is room.",
      trigger: "String.slice",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
