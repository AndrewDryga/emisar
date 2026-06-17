defmodule Emisar.Checks.VendorViaWrapper do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Iron Law IL-19: wrap a third-party API behind a project-owned module so
      there's one seam to swap, stub, and rate-limit. A raw HTTP client call
      (`Finch`, `Req`, `HTTPoison`, `Tesla`, `Mint`) belongs ONLY in a dedicated
      client/wrapper module (e.g. `Emisar.Billing.PaddleClient.Live`) — never
      scattered across a context or the web layer, where it can't be mocked.

      Allowed: files whose name contains `client` (the wrappers and their
      Live/Stub implementations) and `application.ex` (the Finch pool child
      spec). Everything else in `lib/` must go through a wrapper.
      """
    ]

  @http_clients [:Finch, :Req, :HTTPoison, :Tesla, :Mint]

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
    String.contains?(filename, "/lib/") and
      not String.contains?(filename, "/test/") and
      not String.contains?(Path.basename(filename), "client") and
      not String.ends_with?(filename, "/application.ex")
  end

  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when is_atom(fun) and is_list(args) do
    if List.last(parts) in @http_clients do
      {ast, put_issue(ctx, issue_for(ctx, meta, "#{List.last(parts)}.#{fun}"))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "IL-19: raw HTTP call #{trigger} outside a client/wrapper module — wrap the vendor " <>
          "API behind a project-owned `*Client` module so it can be swapped and stubbed.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
