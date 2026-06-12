defmodule Emisar.Checks.InlineBroadcast do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      House rule: every PubSub publish goes through a named per-event
      function (`broadcast_auth_key_revoked/1`), grouped in the context's
      `# -- PubSub ----` section.

      An `Emisar.PubSub.broadcast/2` call inside any other function is an
      inline broadcast at a mutation site — the topic and message shape
      stop reading in one place.
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
      not String.ends_with?(filename, "lib/emisar/pubsub.ex")
  end

  defp walk({def_kind, _, [head | body]} = ast, ctx) when def_kind in [:def, :defp] do
    name = def_name(head)

    if is_atom(name) and not String.starts_with?(Atom.to_string(name), "broadcast") do
      {ast, flag_broadcast_calls(body, ctx)}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp def_name({:when, _, [inner | _]}), do: def_name(inner)
  defp def_name({name, _, _}) when is_atom(name), do: name
  defp def_name(_), do: nil

  defp flag_broadcast_calls(body, ctx) do
    {_, ctx} =
      Macro.prewalk(body, ctx, fn
        {{:., _, [{:__aliases__, meta, parts}, :broadcast]}, _, args} = node, acc
        when is_list(args) ->
          if List.last(parts) == :PubSub do
            {node, put_issue(acc, issue_for(acc, meta, "PubSub.broadcast"))}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    ctx
  end

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: inline PubSub.broadcast at a mutation site — publish through " <>
          "a named per-event broadcast_* function in the context's PubSub section.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
