defmodule Emisar.Checks.AcronymModuleCase do
  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      House rule: an acronym is all-caps in a module name — `EmisarWeb.SCIM`,
      `Emisar.SSO.OIDC`, `EmisarWeb.MCP.*`, not `Scim`/`Sso`/`Oidc`/`Mcp`.
      CamelCase capitalizes each word; an initialism is one all-caps unit.

      (snake_case identifiers stay lowercase — `scim_token`, the `/scim/v2`
      path — this is module/alias segments only. `ApiKeys` is the accepted
      casing for that context and is NOT flagged.)
      """
    ]

  @miscased %{Scim: "SCIM", Sso: "SSO", Oidc: "OIDC", Mcp: "MCP"}

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    result = Credo.Code.prewalk(source_file, &walk/2, ctx)
    result.issues
  end

  defp walk({:__aliases__, meta, parts} = ast, ctx) when is_list(parts) do
    bad = Enum.filter(parts, &Map.has_key?(@miscased, &1))
    {ast, Enum.reduce(bad, ctx, fn part, acc -> put_issue(acc, issue_for(acc, meta, part)) end)}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, part) do
    format_issue(
      ctx,
      message:
        "Acronym `#{part}` must be all-caps in a module name — write `#{@miscased[part]}`.",
      trigger: "#{part}",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
