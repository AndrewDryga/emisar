defmodule Emisar.Checks.EnumOverValidateInclusion do
  use Credo.Check,
    base_priority: :normal,
    category: :design,
    explanations: [
      check: """
      House rule (§3): use `Ecto.Enum` for a fixed string-set field, never a
      `:string` field plus `validate_inclusion` over a literal list. The enum
      casts to atoms, validates inclusion on cast for free, and keeps the DB
      value as the string form.

      Matched: `validate_inclusion(changeset, :field, [..])` or `… , @attr)` in
      a changeset module — a literal/module-attr value set is the "fixed
      string-set" signal. A runtime/computed set (a bound variable) is allowed.
      The two sanctioned `:string` exceptions (Subscription.status/plan) drop or
      keep their inclusion deliberately; document them with a disable-line.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.ends_with?(source_file.filename, "/changeset.ex") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  # imported form: validate_inclusion(changeset, :field, values [, opts])
  defp walk({:validate_inclusion, meta, [_cs, field, values | _]} = ast, ctx) do
    {ast, flag_if_fixed(ctx, meta, field, values)}
  end

  # remote form: Ecto.Changeset.validate_inclusion(changeset, :field, values [, opts])
  defp walk({{:., _, [_, :validate_inclusion]}, meta, [_cs, field, values | _]} = ast, ctx) do
    {ast, flag_if_fixed(ctx, meta, field, values)}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp flag_if_fixed(ctx, meta, field, values) do
    if fixed_set?(values),
      do: put_issue(ctx, issue_for(ctx, meta, field)),
      else: ctx
  end

  defp fixed_set?(values) when is_list(values), do: true
  defp fixed_set?({:@, _, _}), do: true
  defp fixed_set?(_), do: false

  defp issue_for(ctx, meta, field) do
    name = if is_atom(field), do: ":#{field}", else: "the field"

    format_issue(
      ctx,
      message:
        "§3: validate_inclusion on #{name} over a fixed set — make it an `Ecto.Enum` " <>
          "(casts + validates inclusion for free), not `:string` + validate_inclusion.",
      trigger: "validate_inclusion",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
