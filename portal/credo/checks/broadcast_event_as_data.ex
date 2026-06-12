defmodule Emisar.Checks.BroadcastEventAsData do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      House rule: per-event broadcast functions, not event names as data.

      A `broadcast_*` call that passes a string literal is smuggling the
      event name in as data (`broadcast_change(key, "auth_key.revoked")`).
      The event IS the function — `broadcast_auth_key_revoked(key)` — and
      the literal topic + message tuple live inside it.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "apps/emisar/lib/emisar/") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({fun, meta, args} = ast, ctx) when is_atom(fun) and is_list(args) do
    if String.starts_with?(Atom.to_string(fun), "broadcast_") and
         Enum.any?(args, &is_binary/1) do
      {ast, put_issue(ctx, issue_for(ctx, meta, "#{fun}"))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: event name passed as data to #{trigger} — make the event a " <>
          "dedicated broadcast_<event> function owning its literal topic + tuple.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
