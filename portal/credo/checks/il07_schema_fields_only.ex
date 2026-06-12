defmodule Emisar.Checks.IL07SchemaFieldsOnly do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      Iron Law IL-7: schema modules are fields + associations only.

      A schema is a data shape — `cast`/`validate_*` pipelines and the
      `changeset`/`create`/`update` builders live in `Schema.Changeset`,
      where they're unit-testable and composable into a Multi. (Pure
      struct helpers like `User.valid_password?/2` are sanctioned.)
      """
    ]

  @transition_names [:changeset, :create, :update]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if schema_module?(source_file) do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  # Schemas are identified by content, not path: they `use Emisar, :schema`.
  defp schema_module?(source_file) do
    Credo.Code.prewalk(source_file, &find_use_schema/2, false)
  end

  defp find_use_schema({:use, _, [{:__aliases__, _, [:Emisar]}, :schema]} = ast, _acc),
    do: {ast, true}

  defp find_use_schema(ast, acc), do: {ast, acc}

  defp walk({def_kind, _, [head | _]} = ast, ctx) when def_kind in [:def, :defp] do
    case def_name(head) do
      name when name in @transition_names ->
        {ast, put_issue(ctx, issue_for(ctx, def_meta(head), "#{def_kind} #{name}"))}

      _ ->
        {ast, ctx}
    end
  end

  defp walk({fun, meta, args} = ast, ctx) when is_atom(fun) and is_list(args) do
    name = Atom.to_string(fun)

    if (fun == :cast and length(args) >= 2) or String.starts_with?(name, "validate_") do
      {ast, put_issue(ctx, issue_for(ctx, meta, name))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp def_name({:when, _, [inner | _]}), do: def_name(inner)
  defp def_name({name, _, _}) when is_atom(name), do: name
  defp def_name(_), do: nil

  defp def_meta({:when, _, [inner | _]}), do: def_meta(inner)
  defp def_meta({_, meta, _}), do: meta

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "IL-7: changeset logic in a schema module — move cast/validate and the " <>
          "create/update/changeset builders into Schema.Changeset; schemas are " <>
          "fields + associations only.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
