defmodule Emisar.Checks.IL13ObanStringArgs do
  use Credo.Check,
    base_priority: :higher,
    category: :warning,
    explanations: [
      check: """
      Iron Law IL-13: Oban `perform/1` heads pattern-match STRING-key args.

      Job args round-trip through the DB as JSON, so atom keys in the
      `args:` pattern never match a retried job. Match
      `%{"runner_id" => id}`, not `%{runner_id: id}`.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "lib/emisar/workers/") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({def_kind, _, [head | _]} = ast, ctx) when def_kind in [:def, :defp] do
    case perform_args_pattern(head) do
      nil -> {ast, ctx}
      args_pattern -> {ast, check_args_pattern(args_pattern, ctx)}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp perform_args_pattern({:when, _, [inner | _]}), do: perform_args_pattern(inner)

  defp perform_args_pattern({:perform, _, [pattern]}), do: job_args(pattern)
  defp perform_args_pattern(_), do: nil

  # %Oban.Job{args: <pattern>} — pull the args pattern out of the struct match.
  defp job_args({:%, _, [{:__aliases__, _, [:Oban, :Job]}, {:%{}, _, pairs}]}),
    do: Keyword.get(pairs, :args)

  defp job_args(_), do: nil

  defp check_args_pattern({:%{}, meta, pairs}, ctx) do
    atom_keys = for {key, _} <- pairs, is_atom(key), do: key

    case atom_keys do
      [] -> ctx
      [key | _] -> put_issue(ctx, issue_for(ctx, meta, ":#{key}"))
    end
  end

  defp check_args_pattern(_, ctx), do: ctx

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "IL-13: atom key #{trigger} in an Oban args pattern — args round-trip " <>
          "through the DB as JSON; match string keys (%{\"id\" => id}).",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
