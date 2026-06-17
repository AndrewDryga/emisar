defmodule Emisar.Checks.ContextNoMapTakeDrop do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      House rule: field whitelisting is the changeset's `cast/3`, never a
      `Map.take`/`Map.drop` on the input attrs in a context. A mutation that
      may only touch a subset of fields gets its own changeset function (e.g.
      `User.Changeset.profile/2` casts only `full_name`); the context calls
      that — it doesn't pre-filter the attrs map.

      Matched: `Map.take(attrs, …)` / `Map.drop(params, …)` — a first argument
      whose name ends in `attrs` or `params` (the input-attrs convention).
      `Map.take`/`drop` on any other map (payloads, configs) is fine.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "/lib/emisar/") and
         not String.contains?(source_file.filename, "/test/") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({{:., _, [{:__aliases__, meta, [:Map]}, fun]}, _, [{arg, _, mod} | _]} = ast, ctx)
       when fun in [:take, :drop] and is_atom(arg) and is_atom(mod) do
    if attrs_like?(arg) do
      {ast, put_issue(ctx, issue_for(ctx, meta, "Map.#{fun}(#{arg}, …)"))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp attrs_like?(arg) do
    name = Atom.to_string(arg)
    String.ends_with?(name, "attrs") or String.ends_with?(name, "params")
  end

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: #{trigger} pre-filters input fields in a context — whitelist fields in " <>
          "the changeset's `cast/3` (a dedicated changeset fn), not with Map.take/drop.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
