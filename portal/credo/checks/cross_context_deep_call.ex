defmodule Emisar.Checks.CrossContextDeepCall do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      House rule (§1): one context never reaches into ANOTHER context's
      internals. Calling a sibling's `<Schema>.Query.*` or
      `<Schema>.Changeset.*` bypasses its public API and authorization
      boundary — the owning context must expose a (possibly `@doc "Internal"`)
      function instead (`Runs.peek_run_by_id/1`, `Accounts.count_memberships/1`).

      This is the call-site companion to CrossContextDeepAlias (which forbids
      the deep ALIAS): even through the permitted top-level alias
      (`alias Emisar.Runs` → `Runs.ActionRun.Query.x()`) the CALL is a reach-in.
      Calling a sibling's PUBLIC function (`Runs.foo(...)`) is fine — only
      `.Query`/`.Changeset` match. Query modules are exempt: composing another
      schema's `Query.not_deleted/0` in a join is the documented idiom.
      """
    ]

  @special_contexts %{
    "oauth" => "OAuth",
    "api_keys" => "ApiKeys",
    "mcp_operations" => "MCPOperations",
    "sso" => "SSO"
  }

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if relevant?(source_file.filename) do
      ctx =
        Context.build(source_file, params, __MODULE__, %{
          own_context: own_context(source_file.filename),
          aliases: %{}
        })

      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  # lib (not test), with a determinable own context, and NOT a query module
  # (a query module composing a sibling's Query in a join is the documented idiom).
  defp relevant?(filename) do
    # The Audit context legitimately composes every other context's Query in its
    # label/scope resolvers (§2 — Audit.resolve_references); it is the exception.
    String.contains?(filename, "/lib/") and
      not String.contains?(filename, "/test/") and
      not String.ends_with?(filename, "/query.ex") and
      own_context(filename) not in [nil, "Audit"]
  end

  defp own_context(filename) do
    case Regex.run(~r{/lib/emisar/([a-z_0-9]+)(\.ex$|/)}, filename) do
      [_, ctx_dir, _] -> Map.get(@special_contexts, ctx_dir, Macro.camelize(ctx_dir))
      nil -> nil
    end
  end

  # Record `alias Emisar.<Ctx>...` so an aliased call can be resolved to its context.
  defp walk({:alias, _, [{:__aliases__, _, [:Emisar, top | rest]} | opts]} = ast, ctx) do
    {ast,
     %{ctx | aliases: Map.put(ctx.aliases, alias_local(rest, opts, top), Atom.to_string(top))}}
  end

  # alias Emisar.<Ctx>.{A, B} — each branch resolves to context <Ctx>.
  defp walk(
         {:alias, _, [{{:., _, [{:__aliases__, _, [:Emisar, top | _]}, :{}]}, _, branches}]} = ast,
         ctx
       ) do
    aliases =
      Enum.reduce(branches, ctx.aliases, fn
        {:__aliases__, _, parts}, acc -> Map.put(acc, List.last(parts), Atom.to_string(top))
        _, acc -> acc
      end)

    {ast, %{ctx | aliases: aliases}}
  end

  # A remote call: flag if it reaches a FOREIGN context's Query/Changeset module.
  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when is_atom(fun) and is_list(args) do
    {ast, flag_if_foreign(ctx, meta, parts)}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp alias_local(rest, opts, top) do
    cond do
      as_name(opts) != nil -> as_name(opts)
      rest == [] -> top
      true -> List.last(rest)
    end
  end

  defp as_name(opts) do
    opts
    |> List.flatten()
    |> Enum.find_value(fn
      {:as, {:__aliases__, _, parts}} -> List.last(parts)
      _ -> nil
    end)
  end

  defp flag_if_foreign(ctx, meta, parts) do
    owning = owning_context(parts, ctx.aliases)
    # "Repo" is infra (the shared Emisar.Repo.Changeset / Repo.Query helpers), not a context.
    foreign? = owning != nil and owning != ctx.own_context and owning != "Repo"

    if List.last(parts) in [:Query, :Changeset] and foreign? do
      put_issue(ctx, issue_for(ctx, meta, dotted(parts)))
    else
      ctx
    end
  end

  # Fully qualified `Emisar.<Ctx>...` → <Ctx>; aliased `<Local>...` → resolved context.
  defp owning_context([:Emisar, top | _], _aliases), do: Atom.to_string(top)
  defp owning_context([local | _], aliases), do: Map.get(aliases, local)

  defp dotted(parts), do: parts |> Enum.take(-2) |> Enum.map_join(".", &Atom.to_string/1)

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: reaching into a sibling context's #{trigger} — call the owning " <>
          "context's public function instead; Query/Changeset are its internals.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
