defmodule Emisar.Checks.CrossContextDeepAlias do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      House rule: reference ANOTHER context's modules through its top-level
      alias — `alias Emisar.Runs` then `Runs.ActionRun`, never
      `alias Emisar.Runs.ActionRun`. It keeps obvious which context a
      schema belongs to.

      Allowed: a context aliasing its OWN submodules, `Emisar.Auth.Subject`
      (the universal auth carrier), and `Emisar.Repo.*` (infra, not a
      context). Applies to the web app too.
      """
    ]

  @special_contexts %{"oauth" => "OAuth", "api_keys" => "ApiKeys"}

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    filename = source_file.filename

    if String.contains?(filename, "/lib/") and not String.contains?(filename, "/test/") do
      ctx = Context.build(source_file, params, __MODULE__, %{own_context: own_context(filename)})
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  # The file's own context, derived from its directory under lib/emisar/.
  # Web files have none — every cross-context deep alias is foreign there.
  defp own_context(filename) do
    case Regex.run(~r{/lib/emisar/([a-z_0-9]+)(\.ex$|/)}, filename) do
      [_, ctx_dir, _] -> Map.get(@special_contexts, ctx_dir, Macro.camelize(ctx_dir))
      nil -> nil
    end
  end

  # alias Emisar.<Ctx>.<Sub> (single form, possibly with :as)
  defp walk({:alias, _, [{:__aliases__, meta, [:Emisar, top, _ | _] = parts} | _]} = ast, ctx) do
    {ast, flag_if_foreign(ctx, meta, top, parts)}
  end

  # alias Emisar.<Ctx>.{A, B} (multi form)
  defp walk(
         {:alias, _, [{{:., _, [{:__aliases__, meta, [:Emisar, top | _]}, :{}]}, _, _}]} = ast,
         ctx
       ) do
    {ast, flag_if_foreign(ctx, meta, top, [:Emisar, top, :{}])}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp flag_if_foreign(ctx, meta, top, parts) do
    cond do
      top == :Repo -> ctx
      Atom.to_string(top) == ctx.own_context -> ctx
      parts == [:Emisar, :Auth, :Subject] -> ctx
      true -> put_issue(ctx, issue_for(ctx, meta, "Emisar.#{top}"))
    end
  end

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: cross-context deep alias — alias the owning context " <>
          "(alias #{trigger}) and reference its submodules through it " <>
          "(Auth.Subject and Repo.* are the only exceptions).",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
