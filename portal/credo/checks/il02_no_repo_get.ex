defmodule Emisar.Checks.IL02NoRepoGet do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      Iron Law IL-2: never `Repo.get/2`, `Repo.get!/2`, or `Repo.get_by/2`.

      They bypass the Query module and its row-scoping entirely. Build the
      lookup with `Schema.Query.by_id/2` (or another Query helper) and read
      it through `Repo.fetch/3`.
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
    String.contains?(filename, "/lib/") and
      not String.ends_with?(filename, "lib/emisar/repo.ex") and
      not String.contains?(filename, "lib/emisar/repo/")
  end

  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when fun in [:get, :get!, :get_by] and is_list(args) and args != [] do
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
        "IL-2: #{trigger} bypasses the Query module — build the lookup via " <>
          "Schema.Query and read it with Repo.fetch/3.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
