defmodule Emisar.Checks.IL08ChangesetPure do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      Iron Law IL-8: changeset modules are pure — no Repo calls.

      Pure changesets are unit-testable and composable into a Multi. DB
      work belongs in the context that builds the transaction.
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
    String.ends_with?(filename, "/changeset.ex") and
      not String.contains?(filename, "lib/emisar/repo/")
  end

  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when is_atom(fun) and is_list(args) do
    if List.last(parts) == :Repo do
      {ast, put_issue(ctx, issue_for(ctx, meta, "Repo.#{fun}"))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "IL-8: #{trigger} inside a Changeset module — changesets are pure; " <>
          "do the DB work in the context.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
