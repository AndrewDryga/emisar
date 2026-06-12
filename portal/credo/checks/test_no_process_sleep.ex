defmodule Emisar.Checks.TestNoProcessSleep do
  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      House rule (§7): no `Process.sleep` for synchronization in tests —
      use `assert_receive` with an explicit timeout when crossing process
      boundaries.

      Sleeping makes the suite slow when the value is too high and flaky
      when it's too low. A deliberate delay-injection that isn't
      synchronization gets an inline disable with a why-comment.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "/test/") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({{:., _, [{:__aliases__, meta, [:Process]}, :sleep]}, _, args} = ast, ctx)
       when is_list(args) do
    {ast, put_issue(ctx, issue_for(ctx, meta, "Process.sleep"))}
  end

  defp walk({{:., _, [:timer, :sleep]}, meta, args} = ast, ctx) when is_list(args) do
    {ast, put_issue(ctx, issue_for(ctx, meta, ":timer.sleep"))}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: #{trigger} in a test — synchronize with assert_receive " <>
          "(explicit timeout), not wall-clock sleeps.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
