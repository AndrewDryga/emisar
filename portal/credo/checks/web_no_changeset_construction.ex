defmodule Emisar.Checks.WebNoChangesetConstruction do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      House rule (§6): a changeset is BUILT by the domain, not by the adapter.
      `apps/emisar_web` renders and submits forms on the context's
      `change_*/2` builders; it never casts, changes, validates, or
      constrains one itself — `Ecto.Changeset.add_error/4` in a LiveView is
      domain validation living outside the authorization boundary, where no
      context test covers it.

      `import Ecto.Changeset` is banned outright, in every form (`only:` and
      `except:` included): the bare `cast(attrs, [:name])` it brings into
      scope is indistinguishable from a local call, so importing is the one
      bypass no AST check can see. Qualify the read-only calls instead.

      Read-only inspection of an existing changeset IS the form's job and
      stays legal: `changed?`, `fetch_change`, `fetch_field`, `fetch_field!`,
      `get_assoc`, `get_change`, `get_embed`, `get_field`, `traverse_errors`.
      Everything else on `Ecto.Changeset` fails closed — in ordinary code, in
      a function capture, and inside a literal `~H` template, whose body the
      AST keeps as a STRING. Form orchestration the web owns needs none of
      it: `Phoenix.Component.to_form/2` and marking the submit action
      (`Map.put(changeset, :action, :insert)`, a struct update) are untouched
      here.

      Reaching a CONTEXT's own `<Schema>.Changeset` module is a nested-domain
      call and is caught by `Emisar.Checks.WebNoNestedDomainCalls`.
      """
    ]

  # A qualified call written as HEEx TEXT: `A.B.fun(`. The lookbehind keeps the
  # match off a mid-path segment and off a `struct.Field.fun(` access.
  @heex_call ~r/(?<![\w.])((?:[A-Z][A-Za-z0-9_]*\.)+)([a-z_][A-Za-z0-9_]*[?!]?)\(/
  @read_only ~w(changed? fetch_change fetch_field fetch_field! get_assoc get_change
                get_embed get_field traverse_errors)a

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "apps/emisar_web/lib/") do
      ctx = Context.build(source_file, params, __MODULE__, %{aliases: MapSet.new()})
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  # alias Ecto.Changeset  /  alias Ecto.Changeset, as: CS
  defp walk({:alias, _, [{:__aliases__, _, [:Ecto, :Changeset]} | opts]} = ast, ctx) do
    {ast, %{ctx | aliases: MapSet.put(ctx.aliases, local_name(opts))}}
  end

  # alias Ecto.{Changeset, Multi}
  defp walk({:alias, _, [{{:., _, [{:__aliases__, _, [:Ecto]}, :{}]}, _, branches}]} = ast, ctx) do
    aliases =
      Enum.reduce(branches, ctx.aliases, fn
        {:__aliases__, _, [:Changeset]}, acc -> MapSet.put(acc, :Changeset)
        _branch, acc -> acc
      end)

    {ast, %{ctx | aliases: aliases}}
  end

  # import Ecto.Changeset, with or without only:/except: — the import itself is
  # the violation, because the bare calls it opens up leave no remote call to see.
  defp walk({:import, meta, [{:__aliases__, _, [:Ecto, :Changeset]} | _opts]} = ast, ctx) do
    {ast, put_issue(ctx, issue_for(ctx, meta, "import Ecto.Changeset"))}
  end

  # A literal `~H` body reaches the AST as a string, so a call written in the
  # template never reaches the remote-call clause below.
  defp walk({:sigil_H, meta, [{:<<>>, _, parts}, _modifiers]} = ast, ctx) do
    {ast, put_issue(ctx, heex_issues(ctx, parts, body_line(meta)))}
  end

  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when is_atom(fun) and fun != :{} and is_list(args) and is_list(parts) do
    if changeset_module?(parts, ctx.aliases) and fun not in @read_only do
      {ast, put_issue(ctx, issue_for(ctx, meta, "Ecto.Changeset.#{fun}"))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp local_name(opts) do
    opts
    |> List.flatten()
    |> Enum.find_value(:Changeset, fn
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
      fun = String.to_atom(slice(text, name))
      line = start_line + newlines(binary_part(text, 0, start))

      if changeset_module?(module_parts(text, path), ctx.aliases) and fun not in @read_only do
        [issue_for(ctx, [line: line], "Ecto.Changeset.#{fun}")]
      else
        []
      end
    end)
  end

  # The sigil's own line carries `~H`; a heredoc body starts on the next one.
  defp body_line(meta) do
    if meta[:delimiter] == ~s("""), do: meta[:line] + 1, else: meta[:line]
  end

  defp module_parts(text, range) do
    text |> slice(range) |> String.split(".", trim: true) |> Enum.map(&String.to_atom/1)
  end

  defp slice(text, {start, length}), do: binary_part(text, start, length)

  defp newlines(text), do: length(String.split(text, "\n")) - 1

  defp changeset_module?([:Ecto, :Changeset], _aliases), do: true
  defp changeset_module?([local], aliases), do: MapSet.member?(aliases, local)
  defp changeset_module?(_parts, _aliases), do: false

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: #{trigger} in the web layer — a changeset is built and validated by " <>
          "the context's change_*/2 builders; the web only inspects and renders one.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
