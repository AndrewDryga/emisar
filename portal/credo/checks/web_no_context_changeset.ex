defmodule Emisar.Checks.WebNoContextChangeset do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      House rule (§6): forms are built on the context's `change_*/2` builders,
      never by reaching into a context's `<Schema>.Changeset` module from
      `apps/emisar_web`. A changeset is a context write-internal; the web calls
      `Accounts.change_membership/2`, not `Membership.Changeset.update/2`.

      `Ecto.Changeset.*` (the stdlib — `cast`, `validate_*`, `traverse_errors`,
      `apply_changes`) is fine: it's the form-validation toolkit, not a context
      internal. Reading a Query module's UI metadata (`Query.filters/0`, the
      `actor_filter`/`known_*_values` label helpers) is the §6-sanctioned
      web↔Query touch and is intentionally not matched here — the web can't run
      a query anyway (see WebNoRepoCalls).
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?(source_file.filename, "apps/emisar_web/lib/") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when is_atom(fun) and is_list(args) do
    if List.last(parts) == :Changeset and List.first(parts) != :Ecto do
      {ast, put_issue(ctx, issue_for(ctx, meta, "#{tail(parts)}.#{fun}"))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp tail(parts), do: parts |> Enum.take(-2) |> Enum.map_join(".", &Atom.to_string/1)

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: #{trigger} in the web layer — build forms on the context's " <>
          "change_*/2 builders, not a context Changeset module (Ecto.Changeset stdlib is fine).",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
