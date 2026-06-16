defmodule Emisar.Checks.MultilineAliasGroup do
  use Credo.Check,
    base_priority: :low,
    category: :readability,
    explanations: [
      check: """
      House rule: a grouped alias (`alias X.{A, B, C}`) stays on ONE line. When
      the group is too long to fit, split it into MULTIPLE single-line grouped
      aliases — never let the formatter expand one group one-module-per-line.

          # ✅
          alias Emisar.SSO.{Authorizer, DirectoryGroupMember, GroupRoleMapping}
          alias Emisar.SSO.{IdentityProvider, OIDC, UserIdentity}

          # ❌
          alias Emisar.SSO.{
            Authorizer,
            DirectoryGroupMember,
            GroupRoleMapping,
            IdentityProvider,
            OIDC,
            UserIdentity
          }
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    result = Credo.Code.prewalk(source_file, &walk/2, ctx)
    result.issues
  end

  # A grouped alias `alias X.{A, B, ...}` whose keyword + members don't all sit
  # on one source line — i.e. the formatter expanded it across lines.
  defp walk({:alias, meta, [{{:., _, [{:__aliases__, _, _}, :{}]}, _, members}]} = ast, ctx)
       when is_list(members) do
    lines = [meta[:line] | member_lines(members)]

    if length(Enum.uniq(lines)) > 1,
      do: {ast, put_issue(ctx, issue_for(ctx, meta))},
      else: {ast, ctx}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp member_lines(members) do
    for {:__aliases__, member_meta, _} <- members, is_list(member_meta), do: member_meta[:line]
  end

  defp issue_for(ctx, meta) do
    format_issue(
      ctx,
      message:
        "House rule: a multi-line `alias X.{...}` group — split it into multiple " <>
          "single-line grouped aliases instead.",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
