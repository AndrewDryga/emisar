defmodule Emisar.Checks.NoProcessDictionary do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      No process dictionary for ambient request/audit state. `Process.put/2`
      is the ambient channel that let a runner socket's connect IP/UA bleed
      onto engine audit rows running in the same process — the bug the
      `%Emisar.RequestContext{}` refactor removed.

      Request metadata (ip_address / user_agent / request_id /
      mcp_session_id) is a struct: it rides on `%Auth.Subject{}.context` for
      authenticated callers (every `Audit.Events` builder pulls it via
      `actor/1`) and is passed as an explicit `context` argument on pre-auth
      paths. Thread it; never stash it in the process dictionary.

      A genuinely process-local cache that is NOT request/audit state gets an
      inline `# credo:disable-for-next-line` with a why-comment.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "/lib/") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({{:., _, [{:__aliases__, meta, [:Process]}, :put]}, _, args} = ast, ctx)
       when is_list(args) do
    {ast, put_issue(ctx, issue_for(ctx, meta))}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta) do
    format_issue(
      ctx,
      message:
        "Process.put stashes ambient state — request metadata is an " <>
          "%Emisar.RequestContext{} on subject.context (or an explicit context " <>
          "argument on pre-auth paths), never the process dictionary.",
      trigger: "Process.put",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
