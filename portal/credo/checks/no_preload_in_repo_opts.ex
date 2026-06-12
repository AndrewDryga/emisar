defmodule Emisar.Checks.NoPreloadInRepoOpts do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      House rule: contexts never smuggle preloads into Repo opts.

      The caller-facing `preload:` option is fine — the context pops it
      and maps it to the Query module's `with_preloaded_*` helpers via a
      whitelist reducer. What's banned is stuffing preloads into the opts
      the Repo call consumes (a `Keyword.put`/`put_new` of `:preload`, or
      a literal `preload:` in the `Repo.fetch`/`Repo.list` argument list),
      because that bypasses the helpers' soft-delete scoping.
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
    String.contains?(filename, "apps/emisar/lib/emisar/") and
      not String.ends_with?(filename, "/query.ex") and
      not String.ends_with?(filename, "lib/emisar/repo.ex") and
      not String.contains?(filename, "lib/emisar/repo/")
  end

  defp walk({{:., _, [{:__aliases__, meta, [:Keyword]}, fun]}, _, args} = ast, ctx)
       when fun in [:put, :put_new] and is_list(args) do
    # Direct form has :preload as the second arg; the piped form as the first.
    if :preload in Enum.take(args, 2) do
      {ast, put_issue(ctx, issue_for(ctx, meta, "Keyword.#{fun}(:preload)"))}
    else
      {ast, ctx}
    end
  end

  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when fun in [:fetch, :fetch!, :list] and is_list(args) do
    if List.last(parts) == :Repo and Enum.any?(args, &keyword_with_preload?/1) do
      {ast, put_issue(ctx, issue_for(ctx, meta, "Repo.#{fun}(preload:)"))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp keyword_with_preload?(arg) when is_list(arg),
    do: Enum.any?(arg, &match?({:preload, _}, &1))

  defp keyword_with_preload?(_), do: false

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: preload smuggled into Repo opts — pop the caller's preload " <>
          "option and map it to Schema.Query.with_preloaded_* helpers instead.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
