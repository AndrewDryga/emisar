defmodule Emisar.Checks.ChangesetNoTruncate do
  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      House rule: no `DateTime.truncate` timestamp helpers in a changeset.

      Every datetime column is `:utc_datetime_usec`, so a truncate on the way
      into a changeset is either a no-op or a deliberate coarsening that
      belongs nowhere near one. Write `deleted_at: DateTime.utc_now()`
      directly. (A genuinely coarser column is the exception — why-comment +
      inline disable.)

      Truncating `utc_now/0` itself, anywhere, is the built-in
      `Credo.Check.Refactor.UtcNowTruncate`'s job; it also covers the
      `NaiveDateTime` family this check never did.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.ends_with?(source_file.filename, "/changeset.ex") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({{:., _, [{:__aliases__, meta, [:DateTime]}, :truncate]}, _, args} = ast, ctx)
       when is_list(args) do
    {ast, put_issue(ctx, issue_for(ctx, meta))}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta) do
    format_issue(
      ctx,
      message:
        "House rule: DateTime.truncate in a changeset — columns are " <>
          ":utc_datetime_usec and utc_now/0 is already microsecond precision; " <>
          "use DateTime.utc_now() directly.",
      trigger: "DateTime.truncate",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
