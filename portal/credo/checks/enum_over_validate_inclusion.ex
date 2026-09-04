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

      Matched in a changeset module, piped (`|> validate_inclusion(:field,
      [..])` — the spelling a changeset pipeline actually uses) and direct
      (`validate_inclusion(changeset, :field, [..])`), imported or qualified,
      with or without trailing opts. A literal list, `~w` sigil, or
      module-attribute value set is the "fixed string-set" signal; a
      runtime/computed set (a bound variable or a function call) is allowed,
      trailing options and all. The sanctioned `:string` exceptions (the
      Paddle-owned `Subscription` fields) drop or keep their inclusion
      deliberately; document them with a disable-line.
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

  # imported form: validate_inclusion(changeset, :field, values [, opts]), and
  # the piped `|> validate_inclusion(:field, values [, opts])`, whose call node
  # has already consumed the changeset argument.
  defp walk({:validate_inclusion, meta, args} = ast, ctx) when is_list(args) do
    {ast, flag_if_fixed(ctx, meta, args)}
  end

  # remote form: Ecto.Changeset.validate_inclusion(…), piped or not.
  defp walk({{:., _, [_, :validate_inclusion]}, meta, args} = ast, ctx) when is_list(args) do
    {ast, flag_if_fixed(ctx, meta, args)}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  # The field is always the argument immediately before the value set, and only
  # the piped spelling drops the leading changeset — so locating the set locates
  # the field whichever spelling this is, without matching on arity (the piped
  # 4-arity call and the direct 3-arity one are the same shape). Same
  # position-tolerant reading `NoPreloadInRepoOpts` uses for its two forms.
  defp flag_if_fixed(ctx, meta, args) do
    case Enum.split_while(args, &(not fixed_set?(&1))) do
      {[_ | _] = before_set, [_values | _]} ->
        put_issue(ctx, issue_for(ctx, meta, List.last(before_set)))

      _no_fixed_value_set ->
        ctx
    end
  end

  # A trailing `message:`/`allow_nil:` option list is a list too, so the value
  # set is the list that is NOT a keyword list — otherwise a runtime set carrying
  # options (`validate_inclusion(cs, :kind, allowed, message: "…")`) reads as
  # fixed and the field name lands on the wrong argument.
  defp fixed_set?(values) when is_list(values), do: not Keyword.keyword?(values)
  defp fixed_set?({:@, _, _}), do: true
  defp fixed_set?({sigil, _, _}) when sigil in [:sigil_w, :sigil_W], do: true
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
