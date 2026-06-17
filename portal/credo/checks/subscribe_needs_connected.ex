defmodule Emisar.Checks.SubscribeNeedsConnected do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Iron Law IL-18: a LiveView `mount/3` runs twice (the dead static render,
      then the connected socket). Guard every PubSub `subscribe` with
      `connected?(socket)` so the disconnected render doesn't subscribe — an
      unguarded subscribe double-subscribes and leaks.

      Heuristic: a `mount` in `live/` whose body calls `subscribe`/`subscribe_*`
      but never `connected?`. If you subscribe inside a helper, keep the
      `connected?` guard in the same `mount` (or disable-line with a why).
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "/live/") and
         String.ends_with?(source_file.filename, ".ex") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({:def, meta, [head | _]} = ast, ctx) do
    if fn_name(head) == :mount and subscribes?(ast) and not guarded?(ast) do
      {ast, put_issue(ctx, issue_for(ctx, meta))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp subscribes?(node), do: any_node?(node, &subscribe_call?/1)
  defp guarded?(node), do: any_node?(node, &connected_call?/1)

  defp subscribe_call?({{:., _, [_, fun]}, _, _}), do: subscribe_name?(fun)
  defp subscribe_call?({fun, _, args}) when is_atom(fun) and is_list(args), do: subscribe_name?(fun)
  defp subscribe_call?(_), do: false

  defp subscribe_name?(fun) when is_atom(fun) do
    fun == :subscribe or String.starts_with?(Atom.to_string(fun), "subscribe_")
  end

  defp connected_call?({:connected?, _, _}), do: true
  defp connected_call?({{:., _, [_, :connected?]}, _, _}), do: true
  defp connected_call?(_), do: false

  defp any_node?(ast, pred) do
    {_, found} = Macro.prewalk(ast, false, fn n, acc -> {n, acc or pred.(n)} end)
    found
  end

  defp fn_name({:when, _, [inner | _]}), do: fn_name(inner)
  defp fn_name({name, _, _}) when is_atom(name), do: name
  defp fn_name(_), do: nil

  defp issue_for(ctx, meta) do
    format_issue(
      ctx,
      message:
        "IL-18: mount/3 subscribes without a connected?(socket) guard — mount runs twice, " <>
          "so an unguarded subscribe double-subscribes. Guard it with connected?/1.",
      trigger: "subscribe",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
