defmodule Emisar.Checks.NoDateTimeTruncate do
  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      House rule: no `DateTime.truncate` timestamp helpers.

      Every datetime column is `:utc_datetime_usec` and `DateTime.utc_now/0`
      is already microsecond precision, so truncating `utc_now` is either a
      no-op or a deliberate coarsening that belongs nowhere near a
      changeset. Write `deleted_at: DateTime.utc_now()` directly. (A
      genuinely coarser column is the exception — why-comment + inline
      disable.)
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx =
      Context.build(source_file, params, __MODULE__, %{
        changeset?: String.ends_with?(source_file.filename, "/changeset.ex")
      })

    result = Credo.Code.prewalk(source_file, &walk/2, ctx)
    result.issues
  end

  # DateTime.utc_now() |> DateTime.truncate(...) — prune the node after
  # flagging so the inner truncate call isn't reported a second time.
  defp walk(
         {:|>, _, [{{:., _, [{:__aliases__, _, [:DateTime]}, :utc_now]}, _, []}, piped]} = ast,
         ctx
       ) do
    case piped do
      {{:., _, [{:__aliases__, meta, [:DateTime]}, :truncate]}, _, _} ->
        {nil, put_issue(ctx, issue_for(ctx, meta))}

      _ ->
        {ast, ctx}
    end
  end

  defp walk({{:., _, [{:__aliases__, meta, [:DateTime]}, :truncate]}, _, args} = ast, ctx)
       when is_list(args) do
    cond do
      # DateTime.truncate(DateTime.utc_now(), ...) — always the banned no-op shape.
      match?([{{:., _, [{:__aliases__, _, [:DateTime]}, :utc_now]}, _, []} | _], args) ->
        {ast, put_issue(ctx, issue_for(ctx, meta))}

      # Inside a changeset module any truncate is the helper pattern the rule bans.
      ctx.changeset? ->
        {ast, put_issue(ctx, issue_for(ctx, meta))}

      true ->
        {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta) do
    format_issue(
      ctx,
      message:
        "House rule: DateTime.truncate on a timestamp — columns are " <>
          ":utc_datetime_usec and utc_now/0 is already microsecond precision; " <>
          "use DateTime.utc_now() directly.",
      trigger: "DateTime.truncate",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
