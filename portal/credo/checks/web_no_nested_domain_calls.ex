defmodule Emisar.Checks.WebNoNestedDomainCalls do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      House rule (§6): the web is an ADAPTER. `apps/emisar_web` calls the
      top-level context (`Emisar.Catalog`, `Emisar.Accounts`, `Emisar.Runs`)
      and nothing below it — a nested module (`Catalog.PublishedRegistry`,
      `Accounts.RunnerAccess`, `Runbooks.Authoring`, `Runs.RunnerError`,
      `<Schema>.Query`, `<Schema>.Changeset`) is that context's internal, so
      calling one puts domain behavior in the adapter and lets the boundary
      drift silently.

      Resolved through aliases: `alias Emisar.Catalog` +
      `Catalog.PublishedRegistry.list()`, a deep `alias Emisar.Catalog.
      PublishedRegistry` (with or without `as:`), and grouped aliases all
      match — in ordinary code, in a function capture, and inside a literal
      `~H` template, whose body the AST keeps as a STRING and which would
      otherwise be the one place the boundary crosses unseen.
      `EmisarWeb.*` is the web's own namespace and is never matched.

      Carriers stay legal because they are data, not behavior: a struct
      literal or pattern (`%Accounts.RunnerAccess{mode: :none}` — not a remote
      call at all), `Emisar.Auth.Subject`, which the web authentication
      boundary must construct, and a remote `t/0` reference — but only where a
      type can stand: inside `@spec`, `@type`, `@typep`, or `@opaque`. A
      runtime `Catalog.PublishedRegistry.Pack.t()` is a call like any other.
      """
    ]

  # A qualified call written as HEEx TEXT: `A.B.fun(`. The lookbehind keeps the
  # match off a mid-path segment and off a `struct.Field.fun(` access.
  @heex_call ~r/(?<![\w.])((?:[A-Z][A-Za-z0-9_]*\.)+)([a-z_][A-Za-z0-9_]*[?!]?)\(/
  @type_attributes ~w(spec type typep opaque)a

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "apps/emisar_web/lib/") do
      ctx =
        Context.build(source_file, params, __MODULE__, %{
          aliases: %{},
          type_calls: type_call_positions(source_file)
        })

      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  # alias Emisar.A.B  /  alias Emisar.A.B, as: C
  defp walk({:alias, _, [{:__aliases__, _, parts} | opts]} = ast, ctx) when is_list(parts) do
    {ast, %{ctx | aliases: put_alias(ctx.aliases, local_name(parts, opts), parts)}}
  end

  # alias Emisar.A.{B, C} — every branch resolves against the same base.
  defp walk({:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, branches}]} = ast, ctx)
       when is_list(base) do
    aliases =
      Enum.reduce(branches, ctx.aliases, fn
        {:__aliases__, _, parts}, acc when is_list(parts) ->
          put_alias(acc, List.last(parts), base ++ parts)

        _branch, acc ->
          acc
      end)

    {ast, %{ctx | aliases: aliases}}
  end

  # A literal `~H` body reaches the AST as a string, so a call written in the
  # template never reaches the remote-call clause below.
  defp walk({:sigil_H, meta, [{:<<>>, _, parts}, _modifiers]} = ast, ctx) do
    {ast, put_issue(ctx, heex_issues(ctx, parts, body_line(meta)))}
  end

  # A remote call — flag it when it resolves below a top-level Emisar context.
  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when is_atom(fun) and fun != :{} and is_list(args) and is_list(parts) do
    expanded = parts |> names() |> expand(ctx.aliases)

    if violation?(expanded, fun, args, meta, ctx.type_calls) do
      {ast, put_issue(ctx, issue_for(ctx, meta, trigger(expanded, fun)))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  # Only `Emisar.*` aliases are worth resolving; `EmisarWeb` is a different atom.
  defp put_alias(aliases, local, [:Emisar | _] = parts) when is_atom(local) do
    case names(parts) do
      nil -> aliases
      base -> Map.put(aliases, Atom.to_string(local), base)
    end
  end

  defp put_alias(aliases, _local, _parts), do: aliases

  defp local_name(parts, opts) do
    case as_name(opts) do
      nil -> List.last(parts)
      name -> name
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

  defp heex_issues(ctx, parts, body_line) do
    {issues, _line} =
      Enum.reduce(parts, {[], body_line}, fn
        part, {issues, line} when is_binary(part) ->
          {issues ++ scan_heex(ctx, part, line), line + newlines(part)}

        _interpolation, acc ->
          acc
      end)

    issues
  end

  defp scan_heex(ctx, text, start_line) do
    @heex_call
    |> Regex.scan(text, return: :index)
    |> Enum.flat_map(fn [{start, _length}, path, name] ->
      expanded = text |> slice(path) |> String.split(".", trim: true) |> expand(ctx.aliases)
      line = start_line + newlines(binary_part(text, 0, start))

      if nested_domain?(expanded) and expanded != ~w(Emisar Auth Subject) do
        [issue_for(ctx, [line: line], trigger(expanded, slice(text, name)))]
      else
        []
      end
    end)
  end

  # The sigil's own line carries `~H`; a heredoc body starts on the next one.
  defp body_line(meta) do
    if meta[:delimiter] == ~s("""), do: meta[:line] + 1, else: meta[:line]
  end

  defp slice(text, {start, length}), do: binary_part(text, start, length)

  defp newlines(text), do: length(String.split(text, "\n")) - 1

  # A module path is compared and reported by NAME. The AST carries atoms, but a
  # `~H` body carries raw template text, and minting an atom per segment there
  # would grow the never-collected atom table on every file Credo scans.
  defp names(parts), do: if(Enum.all?(parts, &is_atom/1), do: Enum.map(parts, &Atom.to_string/1))

  defp expand(nil, _aliases), do: nil
  defp expand(["Emisar" | _] = parts, _aliases), do: parts

  defp expand([head | rest], aliases) do
    case Map.get(aliases, head) do
      nil -> nil
      base -> base ++ rest
    end
  end

  defp expand(_parts, _aliases), do: nil

  # Record only remote `t/0` sites inside type attributes. The main walk still
  # visits the whole attribute, so another remote type name cannot inherit the
  # narrow carrier exception by merely appearing beside a legitimate `t/0`.
  defp type_call_positions(source_file) do
    {_ast, positions} =
      source_file
      |> SourceFile.ast()
      |> Macro.prewalk(MapSet.new(), fn
        {:@, _, [{attr, _, args}]}, positions when attr in @type_attributes ->
          {_args, positions} = Macro.prewalk(args, positions, &collect_type_call/2)
          {nil, positions}

        ast, positions ->
          {ast, positions}
      end)

    positions
  end

  defp collect_type_call(
         {{:., _, [{:__aliases__, meta, _parts}, :t]}, _, []} = ast,
         positions
       ) do
    {ast, MapSet.put(positions, position(meta))}
  end

  defp collect_type_call(ast, positions), do: {ast, positions}

  defp position(meta), do: {meta[:line], meta[:column]}

  # The universal auth carrier — the web boundary mints Subjects by design.
  defp violation?(["Emisar", "Auth", "Subject"], _fun, _args, _meta, _type_calls), do: false

  defp violation?(expanded, :t, [], meta, type_calls),
    do: nested_domain?(expanded) and not MapSet.member?(type_calls, position(meta))

  defp violation?(expanded, _fun, _args, _meta, _type_calls), do: nested_domain?(expanded)

  defp nested_domain?(["Emisar", _top, _nested | _]), do: true
  defp nested_domain?(_parts), do: false

  defp trigger(["Emisar" | rest], fun), do: Enum.join(rest ++ [to_string(fun)], ".")

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: #{trigger} in the web layer — the web is an adapter, so call the " <>
          "top-level context; nested domain modules are its internals.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
