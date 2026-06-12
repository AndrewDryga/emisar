defmodule Emisar.Checks.WebNoRepoCalls do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      House rule (§6): the web layer never runs queries — contexts are the
      only public surface LiveViews, controllers, channels, and MCP call.

      A `Repo.*` call in `apps/emisar_web` bypasses the authorization
      boundary entirely. Referencing `Emisar.Repo.*` structs as data types
      (`%Paginator.Metadata{}`, `Filter` — the documented LiveTable
      contract) is fine and not matched here; calls are not.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "apps/emisar_web/lib/") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
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
        "House rule: #{trigger} in the web layer — the web calls context " <>
          "functions only; queries live behind the authorization boundary.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
