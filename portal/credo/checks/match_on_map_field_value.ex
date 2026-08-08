defmodule Emisar.Checks.MatchOnMapFieldValue do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      House rule: `match?/2` is for a SHAPE check, never to test a field's VALUE
      through a BARE MAP pattern.

          # ❌ — silently always-false the day the field moves
          match?({:ok, %{require_sso: true}}, fetch_settings())

          # ✅ — destructure and read the field
          case fetch_settings() do
            {:ok, settings} -> settings.require_sso
            {:error, _reason} -> false
          end

      Why a bare map specifically: a map pattern whose key is absent simply does
      not match, so the expression quietly becomes `false` and no test, compiler
      warning, or reviewer sees it. That is what disabled the `require_sso`
      last-provider guard when the field moved into the settings embed.

      A STRUCT pattern is exempt and is NOT flagged — `%RunbookExecution{status:
      :active}` raises `CompileError: unknown key` if the field moves, so the
      compiler already guards it. Only the silent form is a defect.

      Genuine shape tests stay legal: `match?({:ok, _}, x)`, `match?(%User{}, x)`,
      `match?({:ok, %{}}, x)`.
      """
    ]

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
    String.contains?(filename, "/lib/") and not String.contains?(filename, "/test/")
  end

  defp walk({:match?, meta, [pattern, _subject]} = ast, ctx) do
    if bare_map_field_literal?(pattern) do
      {ast, put_issue(ctx, issue_for(ctx, meta))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  # A struct pattern carries its fields in a `%{}` child, but the compiler
  # already rejects an unknown key there — so descend into the VALUES (a nested
  # bare map is still silent) without judging the struct's own field map.
  defp bare_map_field_literal?({:%, _meta, [_alias, {:%{}, _, pairs}]}),
    do: Enum.any?(pairs, fn {_key, value} -> bare_map_field_literal?(value) end)

  defp bare_map_field_literal?({:%{}, _meta, pairs}) do
    Enum.any?(pairs, fn {_key, value} -> literal?(value) or bare_map_field_literal?(value) end)
  end

  defp bare_map_field_literal?({left, right}),
    do: bare_map_field_literal?(left) or bare_map_field_literal?(right)

  defp bare_map_field_literal?({_form, _meta, args}) when is_list(args),
    do: Enum.any?(args, &bare_map_field_literal?/1)

  defp bare_map_field_literal?(list) when is_list(list),
    do: Enum.any?(list, &bare_map_field_literal?/1)

  defp bare_map_field_literal?(_other), do: false

  # `_`, a bound variable, and a pin are all shape/binding forms, not values.
  defp literal?(value) when is_atom(value) or is_number(value) or is_binary(value), do: true
  defp literal?(_value), do: false

  defp issue_for(ctx, meta) do
    format_issue(
      ctx,
      message:
        "House rule: `match?` tests a field VALUE through a bare map pattern — it goes " <>
          "silently always-false if that field moves. Destructure with `case` and read the " <>
          "field, or use a struct pattern (which the compiler checks).",
      trigger: "match?",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
